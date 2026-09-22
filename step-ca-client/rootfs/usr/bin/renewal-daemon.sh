#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This runs the automatic renewal of one certificate profile. Step-cli renews
# a staged pair, and the callback validates it before atomically promoting it.
# ==============================================================================
set -e

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
STAGE_DIR="$(profile_stage_dir "${PROFILE}" active)"
STAGE_CERT="${STAGE_DIR}/certificate.pem"
STAGE_KEY="${STAGE_DIR}/key.pem"

case "${RENEWAL_METHOD}" in
    renew|rekey)
        ;;
    *)
        bashio::log.fatal "Configuration option for ${PROFILE} renewal_method must be either 'renew' or 'rekey'"
        exit 1
        ;;
esac

bashio::log.info "Starting ${PROFILE} certificate ${RENEWAL_METHOD} daemon"
mkdir -p "${STAGE_DIR}"
cp "${CERTFILE}" "${STAGE_CERT}"
cp "${KEYFILE}" "${STAGE_KEY}"
chmod 0600 "${STAGE_KEY}"
case "${RENEWAL_METHOD}" in
    renew)
        STEPPATH="${STEPPATH}" step ca renew \
            -f \
            --daemon \
            --exec="/usr/bin/promote-certificate.sh ${PROFILE}" \
            "${STAGE_CERT}" "${STAGE_KEY}"
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
            --exec="/usr/bin/promote-certificate.sh ${PROFILE}" \
            "${STAGE_CERT}" "${STAGE_KEY}"
        ;;
esac
