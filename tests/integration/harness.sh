#!/usr/bin/env bash
# shellcheck shell=bash
# Shared disposable-container harness for the integration checks. This file is
# sourced by run.sh; the test cases intentionally remain there.

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
readonly client_name="${run_id}-client-run"
readonly network_name="${run_id}-network"
readonly ca_volume="${run_id}-ca-data"
readonly subject="client.integration.test"
readonly client_server_subject="client-server.integration.test"
readonly client_subject="client-auth.integration.test"
readonly client_san="client-san.integration.test"
readonly ca_image="smallstep/step-ca:0.30.2"
readonly supervisor_image="python:3.13-alpine"
readonly retry_backoff_seconds="${RETRY_BACKOFF_SECONDS:-1}"
readonly server_supervisor_token="integration-test-server-token"
readonly client_supervisor_token="integration-test-client-token"

# Validate the selected platform, container engine, and retry delay.
# Globals:
#   platform
#   container_engine
#   retry_backoff_seconds
# Arguments:
#   None
# Returns:
#   0 when configuration is valid; 2 when a setting is unsupported.
validate_harness_configuration() {
    case "${platform}" in
        linux/amd64|linux/arm64)
            ;;
        *)
            echo "Unsupported PLATFORM: ${platform}" >&2
            return 2
            ;;
    esac

    if [[ ! "${container_engine}" =~ ^[A-Za-z0-9._-]+$ ]] || ! command -v "${container_engine}" >/dev/null; then
        echo "Container engine not found: ${container_engine}" >&2
        return 2
    fi

    if [[ ! "${retry_backoff_seconds}" =~ ^[1-9][0-9]{0,3}$ ]] || ((10#${retry_backoff_seconds} > 3600)); then
        echo 'RETRY_BACKOFF_SECONDS must be an integer between 1 and 3600' >&2
        return 2
    fi
}

# Remove the disposable containers, network, volume, and temporary files.
# Globals:
#   addon_image
#   addon_name
#   ca_name
#   ca_volume
#   client_name
#   container_engine
#   network_name
#   retry_name
#   supervisor_name
#   tmp_dir
# Arguments:
#   None
cleanup() {
    "${container_engine}" rm --force "${retry_name}" "${client_name}" "${addon_name}" "${supervisor_name}" "${ca_name}" >/dev/null 2>&1 || true
    "${container_engine}" network rm "${network_name}" >/dev/null 2>&1 || true
    "${container_engine}" volume rm "${ca_volume}" >/dev/null 2>&1 || true
    "${container_engine}" run --rm --entrypoint /bin/sh \
        --volume "${tmp_dir}:/test" "${addon_image}" \
        -c 'chmod -R a+rwx /test' >/dev/null 2>&1 || true
    rm -rf "${tmp_dir}"
}

# Run a command repeatedly until it succeeds or the attempt limit is reached.
# Globals:
#   attempt (modified)
# Arguments:
#   $1: Description used in the timeout message.
#   $2: Maximum number of attempts.
#   $3 and later: Command and arguments to run for each attempt.
# Returns:
#   0 when the command succeeds; 1 when all attempts time out.
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

# Print the SHA-256 digest of a file in a disposable container.
# Globals:
#   container_engine
# Arguments:
#   $1: Container name.
#   $2: File path inside the container.
# Outputs:
#   Writes the digest to stdout.
file_fingerprint() {
    local container_name="$1"
    local path="$2"

    "${container_engine}" exec "${container_name}" sha256sum "${path}" | awk '{print $1}'
}

# Verify a certificate against a root certificate inside a container.
# Globals:
#   container_engine
# Arguments:
#   $1: Container name.
#   $2: Certificate path inside the container.
#   $3: Root certificate path inside the container.
# Returns:
#   The exit status from step certificate verify.
verify_certificate() {
    local container_name="$1"
    local certificate_path="$2"
    local root_path="$3"

    "${container_engine}" exec "${container_name}" step certificate verify \
        "${certificate_path}" -roots="${root_path}"
}

# Print logs from the add-on, Supervisor mock, and certificate authority.
# Globals:
#   addon_name
#   ca_name
#   container_engine
#   supervisor_name
# Arguments:
#   None
# Outputs:
#   Writes container labels and logs to stderr.
show_container_logs() {
    echo '--- step-ca-client logs ---' >&2
    "${container_engine}" logs "${addon_name}" >&2 || true
    echo '--- Supervisor mock logs ---' >&2
    "${container_engine}" logs "${supervisor_name}" >&2 || true
    echo '--- step-ca logs ---' >&2
    "${container_engine}" logs "${ca_name}" >&2 || true
}

# Append matching deprecation messages from a container to the report file.
# Globals:
#   container_engine
#   deprecation_notices_file
# Arguments:
#   $1: Container name.
collect_deprecation_notices() {
    local container_name="$1"
    local notices

    notices="$("${container_engine}" logs "${container_name}" 2>&1 | \
        grep --ignore-case --extended-regexp 'deprecated|deprecat|legacy' || true)"
    if [[ -n "${notices}" ]]; then
        printf '%s\n%s\n' "--- ${container_name} ---" "${notices}" >>"${deprecation_notices_file}"
    fi
}

# Print the accumulated deprecation report when it contains any messages.
# Globals:
#   deprecation_notices_file
# Arguments:
#   None
# Outputs:
#   Writes the report to stdout when it contains messages.
report_deprecation_notices() {
    if [[ -s "${deprecation_notices_file}" ]]; then
        echo
        echo '=== Deprecation and legacy notices ==='
        cat "${deprecation_notices_file}"
    fi
}

# Write server-profile options to the disposable add-on's options file.
# Globals:
#   ca_fingerprint
#   options_file
#   retry_backoff_seconds
#   subject
# Arguments:
#   $1: Server certificate issuance token.
# Returns:
#   0 when the options are written; nonzero if input validation fails.
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
        '  "renewal_threshold": "66%",' \
        "  \"retry_backoff_seconds\": ${retry_backoff_seconds}," \
        '  "restart_ha": false,' \
        '  "restart_addons": [],' \
        '  "log_level": "info",' \
        '  "key_type": "RSA"' \
        '}' >"${options_file}"
}

# Write server and client profile options to the client integration file.
# Globals:
#   ca_fingerprint
#   client_options_file
#   client_san
#   client_subject
#   client_server_subject
#   retry_backoff_seconds
# Arguments:
#   $1: Server certificate issuance token.
#   $2: Client certificate issuance token.
write_client_options() {
    local server_token="$1"
    local client_issuance_token="$2"

    printf '%s\n' \
        '{' \
        '  "ca_url": "https://ca:9000",' \
        "  \"root_ca_fingerprint\": \"${ca_fingerprint}\"," \
        "  \"token\": \"${server_token}\"," \
        "  \"subjects\": [\"${client_server_subject}\"]," \
        '  "cafile": "ca.pem",' \
        '  "keyfile": "privkey.pem",' \
        '  "certfile": "fullchain.pem",' \
        '  "renewal_method": "renew",' \
        '  "renewal_threshold": "66%",' \
        "  \"retry_backoff_seconds\": ${retry_backoff_seconds}," \
        '  "restart_ha": false,' \
        '  "restart_addons": [],' \
        '  "log_level": "info",' \
        '  "key_type": "RSA",' \
        '  "client_certificate": {' \
        '    "enabled": true,' \
        '    "ca_url": "",' \
        '    "root_ca_fingerprint": "",' \
        "    \"token\": \"${client_issuance_token}\"," \
        "    \"subject\": \"${client_subject}\"," \
        "    \"sans\": [\"${client_san}\"]," \
        '    "cafile": "client-ca.pem",' \
        '    "keyfile": "client-privkey.pem",' \
        '    "certfile": "client-fullchain.pem",' \
        '    "key_type": "RSA",' \
        '    "renewal_method": "renew",' \
        '    "renewal_threshold": "66%",' \
        '    "restart_ha": false,' \
        '    "restart_addons": []' \
        '  }' \
        '}' >"${client_options_file}"
}

# Start an add-on container with its options, SSL directory, and token.
# Globals:
#   addon_image
#   container_engine
#   network_name
#   platform
# Arguments:
#   $1: Container name.
#   $2: Options file path on the host.
#   $3: SSL directory path on the host.
#   $4: Supervisor token.
#   $5 and later: Additional container-engine arguments.
start_addon() {
    local name="$1"
    local options="$2"
    local ssl="$3"
    local supervisor_token="$4"
    shift 4

    "${container_engine}" run --detach --name "${name}" --network "${network_name}" \
        --platform "${platform}" \
        --volume "${options}:/data/options.json:ro" \
        --volume "${ssl}:/ssl" \
        --env "SUPERVISOR_TOKEN=${supervisor_token}" \
        "$@" "${addon_image}" >/dev/null
}

# Start the server-profile add-on container.
# Globals:
#   options_file
#   server_supervisor_token
#   ssl_dir
# Arguments:
#   $1: Container name.
#   $2 and later: Additional container-engine arguments.
start_server_addon() {
    local name="$1"
    shift

    start_addon "${name}" "${options_file}" "${ssl_dir}" \
        "${server_supervisor_token}" "$@"
}

# Start the client-profile add-on container.
# Globals:
#   client_name
#   client_options_file
#   client_ssl_dir
#   client_supervisor_token
# Arguments:
#   None
start_client_addon() {
    start_addon "${client_name}" "${client_options_file}" "${client_ssl_dir}" \
        "${client_supervisor_token}"
}

# Start the mock Supervisor and wait for its health endpoint.
# Globals:
#   client_options_file
#   client_supervisor_token
#   container_engine
#   options_file
#   platform
#   root_dir
#   server_supervisor_token
#   supervisor_image
#   network_name
#   supervisor_name
# Returns:
#   0 when the mock becomes healthy; nonzero on startup failure or timeout.
start_supervisor_mock() {
    "${container_engine}" run --detach --name "${supervisor_name}" --network "${network_name}" \
        --network-alias supervisor --platform "${platform}" \
        --env SERVER_OPTIONS_FILE=/server-options.json \
        --env CLIENT_OPTIONS_FILE=/client-options.json \
        --env "SERVER_SUPERVISOR_TOKEN=${server_supervisor_token}" \
        --env "CLIENT_SUPERVISOR_TOKEN=${client_supervisor_token}" \
        --volume "${options_file}:/server-options.json:ro" \
        --volume "${client_options_file}:/client-options.json:ro" \
        --volume "${root_dir}/tests/integration/supervisor_mock.py:/server.py:ro" \
        "${supervisor_image}" python /server.py >/dev/null

    wait_for 'the Supervisor mock' 30 \
        "${container_engine}" exec "${supervisor_name}" python -c \
            "from urllib.request import urlopen; urlopen('http://127.0.0.1/health')"
}

# Create the temporary test environment and issue server and client tokens.
# Globals:
#   addon_image
#   ca_image
#   ca_fingerprint
#   ca_name
#   ca_volume
#   client_options_file (set)
#   client_san
#   client_ssl_dir (set)
#   client_server_subject
#   client_subject
#   client_server_token (set)
#   client_token (set)
#   container_engine
#   deprecation_notices_file (set)
#   network_name
#   options_file (set)
#   platform
#   root_dir
#   ssl_dir (set)
#   subject
#   tmp_dir (set)
#   token (set)
# Arguments:
#   None
initialize_harness() {
    validate_harness_configuration

    tmp_dir="$(mktemp -d)"
    readonly tmp_dir
    readonly ssl_dir="${tmp_dir}/ssl"
    readonly client_ssl_dir="${tmp_dir}/client-ssl"
    readonly options_file="${tmp_dir}/options.json"
    readonly client_options_file="${tmp_dir}/client-options.json"
    readonly deprecation_notices_file="${tmp_dir}/deprecation-notices.log"
    mkdir "${ssl_dir}" "${client_ssl_dir}"
    trap cleanup EXIT

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
    client_server_token="$("${container_engine}" exec "${ca_name}" step ca token "${client_server_subject}" \
        --ca-url https://ca:9000 \
        --root /home/step/certs/root_ca.crt \
        --password-file /home/step/secrets/password)"
    readonly client_server_token
    client_token="$("${container_engine}" exec "${ca_name}" step ca token "${client_subject}" \
        --san="${client_san}" --ca-url https://ca:9000 \
        --root /home/step/certs/root_ca.crt \
        --password-file /home/step/secrets/password)"
    readonly client_token
    write_options "${token}"
    write_client_options "${client_server_token}" "${client_token}"
    start_supervisor_mock
}
