#!/usr/bin/env bash
# shellcheck shell=bash
# Run the add-on against a disposable step-ca instance. This intentionally does
# not require a Home Assistant Supervisor: restart options are disabled below.
set -euo pipefail

# shellcheck source=tests/integration/harness.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness.sh"

run_test() {
    local name="$1"
    shift

    echo
    echo "=== ${name} ==="
    "$@"
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
}

test_renewal_preserves_private_key() {
    "${container_engine}" exec "${addon_name}" step ca renew -f \
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
    "${container_engine}" exec "${addon_name}" step ca rekey -f --kty=RSA \
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
        bash -c "test \"\$(${container_engine} logs '${retry_name}' 2>&1 | grep -Fc 'Starting certificate renew daemon')\" -ge 2"
}

main() {
    initialize_harness

    run_test 'Initial certificate issuance' test_initial_certificate_issuance
    run_test 'Renewal preserves the private key' test_renewal_preserves_private_key
    run_test 'Rekey replaces the private key' test_rekey_replaces_private_key
    run_test 'Renewal daemon retries after backoff' test_renewal_daemon_retries_after_backoff

    echo
    echo "Integration checks passed for ${platform}"
}

main "$@"
