#!/command/with-contenv bashio
# shellcheck shell=bash
set -e
umask 077
# shellcheck source=/dev/null
source /usr/bin/helpers.sh

PROFILE="${1:?Certificate profile is required}"
validate_profile "${PROFILE}"
# Read this profile's settings once at startup; the loop below reuses them.
# Restart the add-on to apply certificate configuration changes.
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
METHOD="$(profile_config "${PROFILE}" renewal_method)"
THRESHOLD="$(profile_config "${PROFILE}" renewal_threshold)"
KEY_TYPE="$(profile_config "${PROFILE}" key_type)"
STEPPATH="$(profile_step_path "${PROFILE}")"
RECOVERY_DIR="$(profile_recovery_dir "${PROFILE}")"
PENDING_CERT="${RECOVERY_DIR}/pending-certificate.pem"
PENDING_KEY="${RECOVERY_DIR}/pending-key.pem"
STATE_DIR=/run/step-ca-telemetry
STATE_FILE="${STATE_DIR}/${PROFILE}.state"
LAST_SUCCESS="/data/step-ca-${PROFILE}-last-renewal"

# Validate profile settings.
case "${METHOD}" in
    renew|rekey) ;;
    *) bashio::log.fatal "Invalid ${PROFILE} renewal_method"; exit 1 ;;
esac
if [[ "${METHOD}" == rekey ]]; then
    case "${KEY_TYPE}" in
        EC|OKP|RSA) ;;
        *) bashio::log.fatal "Invalid ${PROFILE} key_type"; exit 1 ;;
    esac
fi
valid_threshold=false
if [[ ${#THRESHOLD} -le 64 ]]; then
    if [[ "${THRESHOLD}" =~ ^([0-9]{1,3})%$ ]]; then
        if ((10#${BASH_REMATCH[1]} <= 100)); then valid_threshold=true; fi
    elif [[ "${THRESHOLD}" =~ ^([0-9]+([.][0-9]+)?[smh])+$ ]]; then
        valid_threshold=true
    fi
fi
if [[ "${valid_threshold}" != true ]]; then
    bashio::log.warning "Invalid ${PROFILE} renewal_threshold; using 66%"
    THRESHOLD='66%'
fi
interval="$(bashio::config 'renewal_check_interval_seconds')"
if [[ ! "${interval}" =~ ^[1-9][0-9]{0,5}$ ]] || ((10#${interval} > 86400)); then
    bashio::log.warning 'Invalid renewal_check_interval_seconds; using 3600'
    interval=3600
fi
backoff="$(bashio::config 'retry_backoff_seconds')"
if [[ ! "${backoff}" =~ ^[1-9][0-9]{0,3}$ ]] || ((10#${backoff} > 3600)); then
    backoff=60
fi

# Create the state directory if it does not exist.
mkdir -p "${STATE_DIR}"

# Write the current renewal status to the profile's state file atomically.
# Globals:
#   STATE_FILE
#   due
#   failure
# Arguments:
#   None
# Returns:
#   0 when the state file is written; nonzero if writing or renaming fails.
write_state() {
    local temp
    temp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
    printf '%s\n%s\n' "${due}" "${failure}" >"${temp}"
    mv -f -- "${temp}" "${STATE_FILE}"
}

due=unknown
failure=off
write_state
prepare_recovery_dir "${PROFILE}"
certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
bashio::log.info "Starting ${PROFILE} certificate renewal checks"
while true; do
    check_result=0
    STEPPATH="${STEPPATH}" step certificate needs-renewal "${CERTFILE}" \
        "--expires-in=${THRESHOLD}" >/dev/null 2>&1 || check_result=$?
    case "${check_result}" in
        0) due=on ;;
        1) due=off ;;
        *)
            due=unknown
            write_state
            bashio::log.warning "${PROFILE} certificate renewal check failed (exit ${check_result})"
            sleep "${backoff}"
            continue
            ;;
    esac

    write_state
    if [[ "${due}" == off ]]; then
        sleep "${interval}"
        continue
    fi
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
    result=0
    if [[ "${METHOD}" == renew ]]; then
        cp -- "${KEYFILE}" "${PENDING_KEY}"
        chmod 0600 "${PENDING_KEY}"
        STEPPATH="${STEPPATH}" step ca renew -f "--out=${PENDING_CERT}" \
            "${CERTFILE}" "${KEYFILE}" >/dev/null || result=$?
    else
        STEPPATH="${STEPPATH}" step ca rekey -f "--kty=${KEY_TYPE}" \
            "--out-cert=${PENDING_CERT}" "--out-key=${PENDING_KEY}" \
            "${CERTFILE}" "${KEYFILE}" >/dev/null || result=$?
    fi
    if ((result == 0)) && certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}"; then
        if ! copy_certificate_pair "${PENDING_CERT}" "${PENDING_KEY}" "${CERTFILE}" "${KEYFILE}" ||
            ! certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}" ||
            [[ "$(step certificate fingerprint "${CERTFILE}")" != "$(step certificate fingerprint "${PENDING_CERT}")" ]]; then
            failure=on
            write_state
            bashio::log.error "${PROFILE} certificate installation failed; restarting for startup recovery"
            exit 1
        fi
        bashio::log.info "Installed renewed ${PROFILE} certificate at ${CERTFILE}"
        date -u +'%Y-%m-%dT%H:%M:%SZ' >"${LAST_SUCCESS}"
        failure=off
        due=off
        write_state
        if /usr/bin/reload-certificates.sh "${PROFILE}"; then
            save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
            rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
        else
            bashio::log.warning "${PROFILE} consumer reload failed; startup recovery will retry"
        fi
        bashio::log.info "${PROFILE} certificate renewed"
        sleep "${interval}"
        continue
    fi
    failure=on
    write_state
    bashio::log.warning "${PROFILE} certificate ${METHOD} failed; retrying in ${backoff} seconds"
    sleep "${backoff}"
done
