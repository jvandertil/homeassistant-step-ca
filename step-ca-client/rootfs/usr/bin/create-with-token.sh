#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This runs the initial creation of the certificate from a one-time token
# ==============================================================================
set -e
umask 077

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
RECOVERY_DIR="$(profile_recovery_dir "${PROFILE}")"
PENDING_CERT="${RECOVERY_DIR}/pending-certificate.pem"
PENDING_KEY="${RECOVERY_DIR}/pending-key.pem"
prepare_recovery_dir "${PROFILE}"
rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"

# Do not enable shell tracing here: it would disclose the one-time token in
# Home Assistant's add-on logs.
STEPPATH="${STEPPATH}" step ca certificate -f "--kty=${KEYTYPE}" "--token=${TOKEN}" \
    "${MAINSUBJECT}" "${PENDING_CERT}" "${PENDING_KEY}"
chmod 0600 "${PENDING_KEY}"
certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}"
copy_certificate_pair "${PENDING_CERT}" "${PENDING_KEY}" "${CERTFILE}" "${KEYFILE}"
certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
/usr/bin/reload-certificates.sh "${PROFILE}"
save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
