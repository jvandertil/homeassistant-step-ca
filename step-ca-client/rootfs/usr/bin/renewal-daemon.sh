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
prepare_recovery_dir "${PROFILE}"
certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
if ! certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}" ||
    [[ "$(step certificate fingerprint "${CERTFILE}")" != "$(step certificate fingerprint "${RECOVERY_CERT}")" ]]; then
    save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
fi
STEP_ARGS=(-f --daemon "--exec=/usr/bin/renewal-complete.sh ${PROFILE}")
if [[ "${RENEWAL_METHOD}" == rekey ]]; then
    case "${KEY_TYPE}" in
        EC|OKP|RSA) ;;
        *)
            bashio::log.fatal "Configuration option for ${PROFILE} key_type must be EC, OKP, or RSA"
            exit 1
            ;;
    esac
    STEP_ARGS+=("--kty=${KEY_TYPE}")
fi

STEPPATH="${STEPPATH}" step ca "${RENEWAL_METHOD}" "${STEP_ARGS[@]}" \
    "${CERTFILE}" "${KEYFILE}"
