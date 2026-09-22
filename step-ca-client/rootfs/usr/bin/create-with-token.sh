#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This runs the initial creation of the certificate from a one-time token
# ==============================================================================
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh
set_debug

PROFILE="${1:-server}"
validate_profile "${PROFILE}"
bashio::log.warning "Previous ${PROFILE} certificate not valid for renewal, forcing creation using token"

KEYTYPE="$(profile_config "${PROFILE}" key_type)"
TOKEN="$(profile_config "${PROFILE}" token)"
MAINSUBJECT="$(profile_subject "${PROFILE}")"
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
STEPPATH="$(profile_step_path "${PROFILE}")"
STAGE_DIR="$(profile_stage_dir "${PROFILE}" initial)"
STAGE_CERT="${STAGE_DIR}/certificate.pem"
STAGE_KEY="${STAGE_DIR}/key.pem"
mkdir -p "${STAGE_DIR}"

# Do not enable shell tracing here: it would disclose the one-time token in
# Home Assistant's add-on logs.
STEPPATH="${STEPPATH}" step ca certificate -f "--kty=${KEYTYPE}" "--token=${TOKEN}" \
    "${MAINSUBJECT}" "${STAGE_CERT}" "${STAGE_KEY}"
test -s "${STAGE_CERT}" && test -s "${STAGE_KEY}"
step certificate verify "${STAGE_CERT}" \
    -roots="${STEPPATH}/certs/root_ca.crt"
promote_certificate_pair "${STAGE_CERT}" "${STAGE_KEY}" "${CERTFILE}" "${KEYFILE}"
/usr/bin/reload-certificates.sh "${PROFILE}"
