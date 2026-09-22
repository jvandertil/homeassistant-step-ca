#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This runs the automatic renewal of the certificates
# ==============================================================================
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh
set_debug

CERTFILE="$(ssl_file_path 'certfile')"
KEYFILE="$(ssl_file_path 'keyfile')"
RENEWAL_METHOD="$(bashio::config 'renewal_method')"
KEY_TYPE="$(bashio::config 'key_type')"

case "${RENEWAL_METHOD}" in
    renew|rekey)
        ;;
    *)
        bashio::log.fatal "Configuration option 'renewal_method' must be either 'renew' or 'rekey'"
        exit 1
        ;;
esac

bashio::log.info "Starting certificate ${RENEWAL_METHOD} daemon"
#running following in subshell hides the command output until complete
if [[ ${STEPDEBUG} -eq 1 ]];then set -x; fi;
case "${RENEWAL_METHOD}" in
    renew)
        step ca renew \
            -f \
            --daemon \
            --exec="/usr/bin/reload-certificates.sh" \
            "${CERTFILE}" "${KEYFILE}"
        ;;
    rekey)
        case "${KEY_TYPE}" in
            EC|OKP|RSA)
                ;;
            *)
                bashio::log.fatal "Configuration option 'key_type' must be EC, OKP, or RSA"
                exit 1
                ;;
        esac

        step ca rekey \
            -f \
            --kty="${KEY_TYPE}" \
            --daemon \
            --exec="/usr/bin/reload-certificates.sh" \
            "${CERTFILE}" "${KEYFILE}"
        ;;
esac
