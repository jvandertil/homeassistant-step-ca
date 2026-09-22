#!/usr/bin/env bash
# shellcheck shell=bash
# Run the add-on against a disposable step-ca instance. This intentionally does
# not require a Home Assistant Supervisor: restart options are disabled below.
set -euo pipefail

# Do not translate the in-container shell path when this harness is launched
# through Git Bash on Windows with Podman Desktop.
if [[ "${OSTYPE:-}" == msys* ]]; then
    export MSYS2_ARG_CONV_EXCL='/bin/sh'
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly root_dir
readonly platform="${PLATFORM:?Set PLATFORM to linux/amd64 or linux/arm64}"
readonly container_engine="${CONTAINER_ENGINE:-docker}"
readonly run_id="step-ca-integration-${RANDOM}-${RANDOM}"
readonly addon_image="${run_id}-addon"
readonly ca_name="${run_id}-ca"
readonly supervisor_name="${run_id}-supervisor"
readonly addon_name="${run_id}-addon-run"
readonly retry_name="${run_id}-retry-run"
readonly network_name="${run_id}-network"
readonly ca_volume="${run_id}-ca-data"
readonly subject="client.integration.test"
readonly ca_image="smallstep/step-ca:0.30.2"
readonly supervisor_image="python:3.13-alpine"
readonly retry_backoff_seconds="${RETRY_BACKOFF_SECONDS:-1}"

case "${platform}" in
    linux/amd64|linux/arm64)
        ;;
    *)
        echo "Unsupported PLATFORM: ${platform}" >&2
        exit 2
        ;;
esac

if [[ ! "${container_engine}" =~ ^[A-Za-z0-9._-]+$ ]] || ! command -v "${container_engine}" >/dev/null; then
    echo "Container engine not found: ${container_engine}" >&2
    exit 2
fi

if [[ ! "${retry_backoff_seconds}" =~ ^[1-9][0-9]{0,3}$ ]] || ((10#${retry_backoff_seconds} > 3600)); then
    echo 'RETRY_BACKOFF_SECONDS must be an integer between 1 and 3600' >&2
    exit 2
fi

tmp_dir="$(mktemp -d)"
readonly tmp_dir
readonly ssl_dir="${tmp_dir}/ssl"
readonly options_file="${tmp_dir}/options.json"
readonly failing_step="${tmp_dir}/step"
mkdir "${ssl_dir}"

cleanup() {
    "${container_engine}" rm --force "${retry_name}" "${addon_name}" "${supervisor_name}" "${ca_name}" >/dev/null 2>&1 || true
    "${container_engine}" network rm "${network_name}" >/dev/null 2>&1 || true
    "${container_engine}" volume rm "${ca_volume}" >/dev/null 2>&1 || true
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT

wait_for() {
    local description="$1"
    local attempts="$2"
    shift 2

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if "$@"; then
            return 0
        fi
        sleep 1
    done

    echo "Timed out waiting for ${description}" >&2
    return 1
}

key_fingerprint() {
    "${container_engine}" exec "${addon_name}" sha256sum /ssl/privkey.pem | awk '{print $1}'
}

certificate_fingerprint() {
    "${container_engine}" exec "${addon_name}" sha256sum /ssl/fullchain.pem | awk '{print $1}'
}

verify_certificate() {
    "${container_engine}" exec "${addon_name}" step certificate verify \
        /ssl/fullchain.pem -roots=/ssl/ca.pem
}

show_container_logs() {
    echo '--- step-ca-client logs ---' >&2
    "${container_engine}" logs "${addon_name}" >&2 || true
    echo '--- Supervisor mock logs ---' >&2
    "${container_engine}" logs "${supervisor_name}" >&2 || true
    echo '--- step-ca logs ---' >&2
    "${container_engine}" logs "${ca_name}" >&2 || true
}

write_options() {
    local issuance_token="$1"

    if [[ ! "${ca_fingerprint}" =~ ^[A-Fa-f0-9]{64}$ ]] || [[ ! "${issuance_token}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo 'Unexpected certificate authority fingerprint or token format' >&2
        return 1
    fi

    printf '%s\n' \
        '{' \
        '  "ca_url": "https://ca:9000",' \
        "  \"root_ca_fingerprint\": \"${ca_fingerprint}\"," \
        "  \"token\": \"${issuance_token}\"," \
        "  \"subjects\": [\"${subject}\"]," \
        '  "cafile": "ca.pem",' \
        '  "keyfile": "privkey.pem",' \
        '  "certfile": "fullchain.pem",' \
        '  "renewal_method": "renew",' \
        "  \"retry_backoff_seconds\": ${retry_backoff_seconds}," \
        '  "restart_ha": false,' \
        '  "restart_addons": [],' \
        '  "log_level": "info",' \
        '  "key_type": "RSA"' \
        '}' >"${options_file}"
}

start_addon() {
    local name="$1"
    shift

    "${container_engine}" run --detach --name "${name}" --network "${network_name}" \
        --platform "${platform}" \
        --volume "${options_file}:/data/options.json:ro" \
        --volume "${ssl_dir}:/ssl" \
        --env SUPERVISOR_TOKEN=integration-test-token \
        "$@" "${addon_image}" >/dev/null
}

start_supervisor_mock() {
    "${container_engine}" run --detach --name "${supervisor_name}" --network "${network_name}" \
        --network-alias supervisor --platform "${platform}" \
        --env OPTIONS_FILE=/options.json \
        --volume "${options_file}:/options.json:ro" \
        --volume "${root_dir}/tests/integration/supervisor_mock.py:/server.py:ro" \
        "${supervisor_image}" python /server.py >/dev/null

    wait_for 'the Supervisor mock' 30 \
        "${container_engine}" exec "${supervisor_name}" python -c \
            "from urllib.request import urlopen; urlopen('http://127.0.0.1/health')"
}

echo "Building add-on image for ${platform}"
"${container_engine}" build --platform "${platform}" --tag "${addon_image}" "${root_dir}/step-ca-client" >/dev/null
test "$("${container_engine}" image inspect --format '{{.Architecture}}' "${addon_image}")" = "${platform#linux/}"

"${container_engine}" network create "${network_name}" >/dev/null
"${container_engine}" volume create "${ca_volume}" >/dev/null
"${container_engine}" run --detach --name "${ca_name}" --network "${network_name}" \
    --network-alias ca \
    --platform "${platform}" --volume "${ca_volume}:/home/step" \
    --env DOCKER_STEPCA_INIT_NAME=Integration-CA \
    --env DOCKER_STEPCA_INIT_DNS_NAMES=ca \
    --env DOCKER_STEPCA_INIT_PASSWORD=integration-test-password \
    "${ca_image}" >/dev/null

echo 'Waiting for the certificate authority'
wait_for 'the step-ca root certificate' 60 \
    "${container_engine}" exec "${ca_name}" /bin/sh -c 'test -s /home/step/certs/root_ca.crt'
wait_for 'the step-ca health endpoint' 60 \
    "${container_engine}" exec "${ca_name}" step ca health \
        --ca-url https://ca:9000 \
        --root /home/step/certs/root_ca.crt
ca_fingerprint="$("${container_engine}" exec "${ca_name}" step certificate fingerprint /home/step/certs/root_ca.crt)"
readonly ca_fingerprint
token="$("${container_engine}" exec "${ca_name}" step ca token "${subject}" \
    --ca-url https://ca:9000 \
    --root /home/step/certs/root_ca.crt \
    --password-file /home/step/secrets/password)"
readonly token
write_options "${token}"
start_supervisor_mock

echo 'Checking initial certificate issuance'
start_addon "${addon_name}"
if ! wait_for 'initial certificate issuance' 90 \
    "${container_engine}" exec "${addon_name}" test -s /ssl/fullchain.pem; then
    show_container_logs
    exit 1
fi
"${container_engine}" exec "${addon_name}" test -s /ssl/privkey.pem
verify_certificate

initial_key="$(key_fingerprint)"
readonly initial_key
initial_certificate="$(certificate_fingerprint)"
readonly initial_certificate

echo 'Checking renewal preserves the private key'
"${container_engine}" exec "${addon_name}" step ca renew -f \
    --exec=/usr/bin/reload-certificates.sh \
    /ssl/fullchain.pem /ssl/privkey.pem
renewed_key="$(key_fingerprint)"
readonly renewed_key
renewed_certificate="$(certificate_fingerprint)"
readonly renewed_certificate
test "${renewed_key}" = "${initial_key}"
test "${renewed_certificate}" != "${initial_certificate}"

echo 'Checking rekey replaces the private key'
"${container_engine}" exec "${addon_name}" step ca rekey -f --kty=RSA \
    --exec=/usr/bin/reload-certificates.sh \
    /ssl/fullchain.pem /ssl/privkey.pem
rekeyed_key="$(key_fingerprint)"
readonly rekeyed_key
test "${rekeyed_key}" != "${renewed_key}"
verify_certificate

# The shim deliberately contains literal positional parameters for its own shell.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$1" == '\''ca'\'' && "$2" == '\''renew'\'' ]]; then' \
    '    exit 42' \
    'fi' \
    'exec /usr/bin/step "$@"' >"${failing_step}"
chmod 0755 "${failing_step}"

echo 'Checking renewal daemon retry backoff'
"${container_engine}" rm --force "${addon_name}" >/dev/null
start_addon "${retry_name}" --volume "${failing_step}:/usr/local/bin/step:ro"
wait_for 'renewal failure backoff' 30 \
    bash -c "${container_engine} logs '${retry_name}' 2>&1 | grep -Fq 'failed; retrying in ${retry_backoff_seconds} seconds'"
wait_for 'renewal daemon restart after backoff' 30 \
    bash -c "test \"\$(${container_engine} logs '${retry_name}' 2>&1 | grep -Fc 'Starting certificate renew daemon')\" -ge 2"

echo "Integration checks passed for ${platform}"
