#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This runs the automatic renewal of one certificate profile. Step-cli renews
# the live pair, and startup recovery repairs interrupted writes.
# ==============================================================================
set -e
umask 077

# shellcheck source=/dev/null
source /usr/bin/helpers.sh
set_debug

PROFILE="${1:-server}"
validate_profile "${PROFILE}"
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
RENEWAL_METHOD="$(profile_config "${PROFILE}" renewal_method)"
KEY_TYPE="$(profile_config "${PROFILE}" key_type)"
STEPPATH="$(profile_step_path "${PROFILE}")"
RECOVERY_DIR="$(profile_recovery_dir "${PROFILE}")"
RECOVERY_CERT="${RECOVERY_DIR}/certificate.pem"
RECOVERY_KEY="${RECOVERY_DIR}/key.pem"

case "${RENEWAL_METHOD}" in
    renew|rekey)
        ;;
    *)
        bashio::log.fatal "Configuration option for ${PROFILE} renewal_method must be either 'renew' or 'rekey'"
        exit 1
        ;;
esac

bashio::log.info "Starting ${PROFILE} certificate ${RENEWAL_METHOD} daemon"
mkdir -p "${RECOVERY_DIR}"
chmod 0700 "${RECOVERY_DIR}"
certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
if ! certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}" ||
    [[ "$(step certificate fingerprint "${CERTFILE}")" != "$(step certificate fingerprint "${RECOVERY_CERT}")" ]]; then
    copy_certificate_pair "${CERTFILE}" "${KEYFILE}" "${RECOVERY_CERT}" "${RECOVERY_KEY}"
fi
case "${RENEWAL_METHOD}" in
    renew)
        STEPPATH="${STEPPATH}" step ca renew \
            -f \
            --daemon \
            --exec="/usr/bin/renewal-complete.sh ${PROFILE}" \
            "${CERTFILE}" "${KEYFILE}"
        ;;
    rekey)
        case "${KEY_TYPE}" in
            EC|OKP|RSA)
                ;;
            *)
                bashio::log.fatal "Configuration option for ${PROFILE} key_type must be EC, OKP, or RSA"
                exit 1
                ;;
        esac

        STEPPATH="${STEPPATH}" step ca rekey \
            -f \
            --kty="${KEY_TYPE}" \
            --daemon \
            --exec="/usr/bin/renewal-complete.sh ${PROFILE}" \
            "${CERTFILE}" "${KEYFILE}"
        ;;
esac
