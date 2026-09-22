#!/command/with-contenv bashio
# shellcheck shell=bash
# Step invokes this after it has replaced the live certificate and key.
set -e
umask 077

# shellcheck source=/dev/null
source /usr/bin/helpers.sh

PROFILE="${1:-server}"
validate_profile "${PROFILE}"
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
STEPPATH="$(profile_step_path "${PROFILE}")"
RECOVERY_DIR="$(profile_recovery_dir "${PROFILE}")"

if ! certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
    bashio::log.error "Renewed ${PROFILE} certificate and private key do not verify"
    exit 1
fi

/usr/bin/reload-certificates.sh "${PROFILE}"
mkdir -p "${RECOVERY_DIR}"
chmod 0700 "${RECOVERY_DIR}"
copy_certificate_pair "${CERTFILE}" "${KEYFILE}" \
    "${RECOVERY_DIR}/certificate.pem" "${RECOVERY_DIR}/key.pem"
