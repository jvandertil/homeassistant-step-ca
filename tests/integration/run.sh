#!/usr/bin/env bash
# shellcheck shell=bash
# Run the add-on against a disposable step-ca instance. This intentionally does
# not require a Home Assistant Supervisor: restart options are disabled below.
set -euo pipefail

# shellcheck source=tests/integration/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

current_test=''

report_failure() {
    local exit_code="$?"

    if [[ -n "${current_test}" ]]; then
        printf '\033[0;31mFAILED\033[0m %s\n' "${current_test}" >&2
    fi
    exit "${exit_code}"
}

trap report_failure ERR

run_test() {
    local name="$1"
    shift

    echo
    echo "=== ${name} ==="
    current_test="${name}"
    "$@"
    printf '\033[0;32mPASSED\033[0m %s\n' "${name}"
    current_test=''
}

test_initial_certificate_issuance() {
    start_addon "${addon_name}"
    if ! wait_for 'initial certificate issuance' 90 \
        "${container_engine}" exec "${addon_name}" test -s /ssl/fullchain.pem; then
        show_container_logs
        return 1
    fi
    "${container_engine}" exec "${addon_name}" test -s /ssl/privkey.pem
    verify_certificate

    initial_key="$(key_fingerprint)"
    readonly initial_key
    initial_certificate="$(certificate_fingerprint)"
    readonly initial_certificate
    collect_deprecation_notices "${addon_name}"
}

test_client_certificate_disabled_by_default() {
    # The default options deliberately omit a client identity. Its separate s6
    # service must remain dormant and must not create default client key files.
    wait_for 'disabled client certificate profile' 30 \
        bash -c "${container_engine} logs '${addon_name}' 2>&1 | grep -Fq 'Client certificate profile is disabled'"
    "${container_engine}" exec "${addon_name}" test ! -e /ssl/client-privkey.pem
    "${container_engine}" exec "${addon_name}" test ! -e /ssl/client-fullchain.pem
}

test_client_certificate_issuance_and_renewal() {
    # Bashio reads effective options from the Supervisor API; point the mock at
    # the enabled-client profile before starting this second add-on container.
    cp "${client_options_file}" "${options_file}"
    start_client_addon
    if ! wait_for 'client certificate issuance' 90 \
        "${container_engine}" exec "${client_name}" test -s /ssl/client-fullchain.pem; then
        show_container_logs
        "${container_engine}" logs "${client_name}" >&2 || true
        return 1
    fi
    "${container_engine}" exec "${client_name}" test -s /ssl/client-privkey.pem
    "${container_engine}" exec "${client_name}" sh -c \
        "step certificate inspect /ssl/client-fullchain.pem --format json | jq -e --arg subject '${client_subject}' --arg san '${client_san}' '.names | index(\$subject) and index(\$san)' >/dev/null"
    client_key_before="$("${container_engine}" exec "${client_name}" sha256sum /ssl/client-privkey.pem | awk '{print $1}')"
    "${container_engine}" exec --env STEPPATH=/root/.step-client "${client_name}" \
        step ca renew -f --exec='/usr/bin/promote-certificate.sh client' \
        /tmp/step-ca-client-active/certificate.pem /tmp/step-ca-client-active/key.pem
    client_key_after="$("${container_engine}" exec "${client_name}" sha256sum /ssl/client-privkey.pem | awk '{print $1}')"
    test "${client_key_before}" = "${client_key_after}"
}

test_renewal_preserves_private_key() {
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" step ca renew -f \
        --exec=/usr/bin/reload-certificates.sh \
        /ssl/fullchain.pem /ssl/privkey.pem
    renewed_key="$(key_fingerprint)"
    readonly renewed_key
    renewed_certificate="$(certificate_fingerprint)"
    readonly renewed_certificate
    test "${renewed_key}" = "${initial_key}"
    test "${renewed_certificate}" != "${initial_certificate}"
}

test_rekey_replaces_private_key() {
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" step ca rekey -f --kty=RSA \
        --exec=/usr/bin/reload-certificates.sh \
        /ssl/fullchain.pem /ssl/privkey.pem
    rekeyed_key="$(key_fingerprint)"
    readonly rekeyed_key
    test "${rekeyed_key}" != "${renewed_key}"
    verify_certificate
}

test_renewal_daemon_retries_after_backoff() {
    local failing_step="${tmp_dir}/step"

    # The shim deliberately contains literal positional parameters for its own shell.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == '\''ca'\'' && "$2" == '\''renew'\'' ]]; then' \
        '    exit 42' \
        'fi' \
        'exec /usr/bin/step "$@"' >"${failing_step}"
    chmod 0755 "${failing_step}"

    "${container_engine}" rm --force "${addon_name}" >/dev/null
    start_addon "${retry_name}" --volume "${failing_step}:/usr/local/bin/step:ro"
    wait_for 'renewal failure backoff' 30 \
        bash -c "${container_engine} logs '${retry_name}' 2>&1 | grep -Fq 'failed; retrying in ${retry_backoff_seconds} seconds'"
    wait_for 'renewal daemon restart after backoff' 30 \
        bash -c "test \"\$(${container_engine} logs '${retry_name}' 2>&1 | grep -Fc 'Starting server certificate renew daemon')\" -ge 2"
    collect_deprecation_notices "${retry_name}"
}

main() {
    initialize_harness

    run_test 'Initial certificate issuance' test_initial_certificate_issuance
    run_test 'Client certificate is disabled by default' test_client_certificate_disabled_by_default
    run_test 'Client certificate issuance and renewal' test_client_certificate_issuance_and_renewal
    run_test 'Renewal preserves the private key' test_renewal_preserves_private_key
    run_test 'Rekey replaces the private key' test_rekey_replaces_private_key
    run_test 'Renewal daemon retries after backoff' test_renewal_daemon_retries_after_backoff
    report_deprecation_notices

    echo
    echo "Integration checks passed for ${platform}"
}

main "$@"
