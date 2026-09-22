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
    start_server_addon "${addon_name}"
    if ! wait_for 'initial certificate issuance' 90 \
        "${container_engine}" exec "${addon_name}" test -s /ssl/fullchain.pem; then
        show_container_logs
        return 1
    fi
    "${container_engine}" exec "${addon_name}" test -s /ssl/privkey.pem
    verify_certificate "${addon_name}" /ssl/fullchain.pem /ssl/ca.pem

    initial_key="$(file_fingerprint "${addon_name}" /ssl/privkey.pem)"
    readonly initial_key
    initial_certificate="$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)"
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
    start_client_addon
    if ! wait_for 'client certificate issuance' 90 \
        "${container_engine}" exec "${client_name}" sh -c \
            'test -s /ssl/fullchain.pem && test -s /ssl/client-fullchain.pem'; then
        show_container_logs
        "${container_engine}" logs "${client_name}" >&2 || true
        return 1
    fi
    verify_certificate "${client_name}" /ssl/fullchain.pem /ssl/ca.pem
    verify_certificate "${client_name}" /ssl/client-fullchain.pem /ssl/client-ca.pem
    "${container_engine}" exec "${client_name}" sh -c \
        "step certificate inspect /ssl/fullchain.pem --format json | jq -e --arg subject '${client_server_subject}' '.names | index(\$subject)' >/dev/null"
    "${container_engine}" exec "${client_name}" test -s /ssl/client-privkey.pem
    "${container_engine}" exec "${client_name}" sh -c \
        "step certificate inspect /ssl/client-fullchain.pem --format json | jq -e --arg subject '${client_subject}' --arg san '${client_san}' '.names | index(\$subject) and index(\$san)' >/dev/null"
    client_key_before="$(file_fingerprint "${client_name}" /ssl/client-privkey.pem)"
    "${container_engine}" exec --env STEPPATH=/root/.step-client "${client_name}" \
        step ca renew -f --exec='/usr/bin/promote-certificate.sh client' \
        /tmp/step-ca-client-active/certificate.pem /tmp/step-ca-client-active/key.pem
    client_key_after="$(file_fingerprint "${client_name}" /ssl/client-privkey.pem)"
    test "${client_key_before}" = "${client_key_after}"
}

test_renewal_preserves_private_key() {
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" step ca renew -f \
        --exec=/usr/bin/reload-certificates.sh \
        /ssl/fullchain.pem /ssl/privkey.pem
    renewed_key="$(file_fingerprint "${addon_name}" /ssl/privkey.pem)"
    readonly renewed_key
    renewed_certificate="$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)"
    readonly renewed_certificate
    test "${renewed_key}" = "${initial_key}"
    test "${renewed_certificate}" != "${initial_certificate}"
}

test_rekey_replaces_private_key() {
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" step ca rekey -f --kty=RSA \
        --exec=/usr/bin/reload-certificates.sh \
        /ssl/fullchain.pem /ssl/privkey.pem
    rekeyed_key="$(file_fingerprint "${addon_name}" /ssl/privkey.pem)"
    readonly rekeyed_key
    test "${rekeyed_key}" != "${renewed_key}"
    verify_certificate "${addon_name}" /ssl/fullchain.pem /ssl/ca.pem
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
    start_server_addon "${retry_name}" --volume "${failing_step}:/usr/local/bin/step:ro"
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
