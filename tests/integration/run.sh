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
        step ca renew -f --exec='/usr/bin/renewal-complete.sh client' \
        /ssl/client-fullchain.pem /ssl/client-privkey.pem
    client_key_after="$(file_fingerprint "${client_name}" /ssl/client-privkey.pem)"
    test "${client_key_before}" = "${client_key_after}"
    assert_recovery_pair "${client_name}" client /ssl/client-fullchain.pem /ssl/client-privkey.pem
    assert_recovery_pair "${client_name}" server /ssl/fullchain.pem /ssl/privkey.pem
}

test_client_startup_restores_its_own_pair() {
    "${container_engine}" exec "${client_name}" sh -c ': > /ssl/client-fullchain.pem'
    "${container_engine}" rm --force "${client_name}" >/dev/null
    start_client_addon
    wait_for 'client pair restoration' 30 \
        "${container_engine}" exec "${client_name}" cmp \
            /ssl/client-fullchain.pem /ssl/.step-ca-client-recovery/certificate.pem
    assert_recovery_pair "${client_name}" client /ssl/client-fullchain.pem /ssl/client-privkey.pem
    assert_recovery_pair "${client_name}" server /ssl/fullchain.pem /ssl/privkey.pem
}

test_renewal_preserves_private_key() {
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" step ca renew -f \
        --exec='/usr/bin/renewal-complete.sh server' \
        /ssl/fullchain.pem /ssl/privkey.pem
    renewed_key="$(file_fingerprint "${addon_name}" /ssl/privkey.pem)"
    readonly renewed_key
    renewed_certificate="$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)"
    readonly renewed_certificate
    test "${renewed_key}" = "${initial_key}"
    test "${renewed_certificate}" != "${initial_certificate}"
    assert_recovery_pair "${addon_name}" server /ssl/fullchain.pem /ssl/privkey.pem
}

test_rekey_replaces_private_key() {
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" step ca rekey -f --kty=RSA \
        --exec='/usr/bin/renewal-complete.sh server' \
        /ssl/fullchain.pem /ssl/privkey.pem
    rekeyed_key="$(file_fingerprint "${addon_name}" /ssl/privkey.pem)"
    readonly rekeyed_key
    test "${rekeyed_key}" != "${renewed_key}"
    verify_certificate "${addon_name}" /ssl/fullchain.pem /ssl/ca.pem
    assert_recovery_pair "${addon_name}" server /ssl/fullchain.pem /ssl/privkey.pem
}

assert_recovery_pair() {
    local container_name="$1" profile="$2" certificate="$3" key="$4"
    local recovery="/ssl/.step-ca-${profile}-recovery"
    "${container_engine}" exec "${container_name}" sh -c \
        "test \"\$(stat -c %a '${recovery}')\" = 700 && test \"\$(stat -c %a '${recovery}/key.pem')\" = 600 && cmp '${certificate}' '${recovery}/certificate.pem' && cmp '${key}' '${recovery}/key.pem'"
}

restart_server_addon() {
    "${container_engine}" rm --force "${addon_name}" >/dev/null
    start_server_addon "${addon_name}"
}

test_startup_restores_mismatched_active_pair() {
    "${container_engine}" exec "${addon_name}" sh -c ': > /ssl/fullchain.pem'
    "${container_engine}" rm --force "${addon_name}" >/dev/null
    start_server_addon "${addon_name}"
    wait_for 'active pair restoration' 30 \
        "${container_engine}" exec "${addon_name}" cmp /ssl/fullchain.pem /ssl/.step-ca-server-recovery/certificate.pem
    verify_certificate "${addon_name}" /ssl/fullchain.pem /ssl/ca.pem
}

test_startup_keeps_completed_renewal() {
    local new_certificate
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" \
        step ca renew -f /ssl/fullchain.pem /ssl/privkey.pem
    new_certificate="$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)"
    restart_server_addon
    wait_for 'completed renewal recovery' 30 \
        "${container_engine}" exec "${addon_name}" cmp /ssl/fullchain.pem /ssl/.step-ca-server-recovery/certificate.pem
    test "$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)" = "${new_certificate}"
    wait_for 'missed callback restart handling' 30 \
        bash -c "${container_engine} logs '${addon_name}' 2>&1 | grep -Fq 'Completed server renewal found during startup'"
}

test_startup_repairs_partial_recovery() {
    "${container_engine}" exec "${addon_name}" sh -c ': > /ssl/.step-ca-server-recovery/key.pem'
    "${container_engine}" rm --force "${addon_name}" >/dev/null
    start_server_addon "${addon_name}"
    wait_for 'partial recovery repair' 30 \
        "${container_engine}" exec "${addon_name}" cmp /ssl/privkey.pem /ssl/.step-ca-server-recovery/key.pem
    assert_recovery_pair "${addon_name}" server /ssl/fullchain.pem /ssl/privkey.pem
}

test_startup_completes_pending_issuance() {
    local new_token
    new_token="$("${container_engine}" exec "${ca_name}" step ca token "${subject}" \
        --ca-url https://ca:9000 --root /home/step/certs/root_ca.crt \
        --password-file /home/step/secrets/password)"
    "${container_engine}" exec --env STEPPATH=/root/.step-server "${addon_name}" \
        step ca certificate -f --kty=RSA "--token=${new_token}" "${subject}" \
        /ssl/.step-ca-server-recovery/pending-certificate.pem \
        /ssl/.step-ca-server-recovery/pending-key.pem
    "${container_engine}" exec "${addon_name}" sh -c \
        ': > /ssl/fullchain.pem; : > /ssl/.step-ca-server-recovery/certificate.pem'
    "${container_engine}" rm --force "${addon_name}" >/dev/null
    start_server_addon "${addon_name}"
    wait_for 'pending issuance installation' 30 \
        "${container_engine}" exec "${addon_name}" test ! -e /ssl/.step-ca-server-recovery/pending-certificate.pem
    assert_recovery_pair "${addon_name}" server /ssl/fullchain.pem /ssl/privkey.pem
    verify_certificate "${addon_name}" /ssl/fullchain.pem /ssl/ca.pem
}

test_unusable_pairs_reach_token_fallback() {
    "${container_engine}" exec "${retry_name}" sh -c \
        ': > /ssl/fullchain.pem; : > /ssl/.step-ca-server-recovery/certificate.pem'
    "${container_engine}" rm --force "${retry_name}" >/dev/null
    start_server_addon "${addon_name}"
    wait_for 'token fallback after unusable pairs' 30 \
        bash -c "${container_engine} logs '${addon_name}' 2>&1 | grep -Fq 'forcing creation using token'"
}

test_renewal_daemon_retries_after_backoff() {
    local failing_step="${tmp_dir}/step"

    # The shim deliberately contains literal positional parameters for its own shell.
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == '\''certificate'\'' && "$2" == '\''needs-renewal'\'' ]]; then' \
        '    exit 0' \
        'fi' \
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
        bash -c "test \"\$(${container_engine} logs '${retry_name}' 2>&1 | grep -Fc 'certificate renew failed; retrying')\" -ge 2"
    "${container_engine}" exec "${retry_name}" sh -c \
        "test \"\$(sed -n '2p' /run/step-ca-telemetry/server.state)\" = on"
    collect_deprecation_notices "${retry_name}"
}

test_configured_threshold_stages_renewal() {
    local due_step="${tmp_dir}/due-step" key_before certificate_before
    local updated_options="${tmp_dir}/threshold-options.json"
    # shellcheck disable=SC2016
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == '\''certificate'\'' && "$2" == '\''needs-renewal'\'' ]]; then' \
        '    [[ "$4" == '\''--expires-in=1h15m'\'' ]]' \
        '    exit $?' \
        'fi' \
        'exec /usr/bin/step "$@"' >"${due_step}"
    chmod 0755 "${due_step}"
    key_before="$(file_fingerprint "${addon_name}" /ssl/privkey.pem)"
    certificate_before="$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)"
    sed 's/"renewal_threshold": "66%"/"renewal_threshold": "1h15m"/' \
        "${options_file}" >"${updated_options}"
    cat "${updated_options}" >"${options_file}"
    "${container_engine}" rm --force "${addon_name}" >/dev/null
    start_server_addon "${addon_name}" --volume "${due_step}:/usr/local/bin/step:ro"
    if ! wait_for 'configured threshold renewal' 45 \
        "${container_engine}" exec "${addon_name}" test -s /data/step-ca-server-last-renewal; then
        "${container_engine}" logs "${addon_name}" >&2 || true
        return 1
    fi
    test "$(file_fingerprint "${addon_name}" /ssl/fullchain.pem)" != "${certificate_before}"
    test "$(file_fingerprint "${addon_name}" /ssl/privkey.pem)" = "${key_before}"
    assert_recovery_pair "${addon_name}" server /ssl/fullchain.pem /ssl/privkey.pem
    verify_certificate "${addon_name}" /ssl/fullchain.pem /ssl/ca.pem
    sed 's/"renewal_threshold": "1h15m"/"renewal_threshold": "66%"/' \
        "${options_file}" >"${updated_options}"
    cat "${updated_options}" >"${options_file}"
}

main() {
    initialize_harness

    run_test 'Initial certificate issuance' test_initial_certificate_issuance
    run_test 'Client certificate is disabled by default' test_client_certificate_disabled_by_default
    run_test 'Client certificate issuance and renewal' test_client_certificate_issuance_and_renewal
    run_test 'Client startup restores its own pair' test_client_startup_restores_its_own_pair
    run_test 'Renewal preserves the private key' test_renewal_preserves_private_key
    run_test 'Rekey replaces the private key' test_rekey_replaces_private_key
    run_test 'Startup restores a mismatched active pair' test_startup_restores_mismatched_active_pair
    run_test 'Startup keeps a completed renewal' test_startup_keeps_completed_renewal
    run_test 'Startup repairs partial recovery' test_startup_repairs_partial_recovery
    run_test 'Startup completes pending issuance' test_startup_completes_pending_issuance
    run_test 'Configured threshold stages renewal and preserves the key' test_configured_threshold_stages_renewal
    run_test 'Renewal daemon retries after backoff' test_renewal_daemon_retries_after_backoff
    run_test 'Unusable pairs reach token fallback' test_unusable_pairs_reach_token_fallback
    report_deprecation_notices

    echo
    echo "Integration checks passed for ${platform}"
}

main "$@"
