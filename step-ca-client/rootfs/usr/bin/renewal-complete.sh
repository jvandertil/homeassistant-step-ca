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
PENDING_CERT="${RECOVERY_DIR}/pending-certificate.pem"
PENDING_KEY="${RECOVERY_DIR}/pending-key.pem"

if ! certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
    bashio::log.error "Renewed ${PROFILE} certificate and private key do not verify"
    exit 1
fi

# step ca renew has installed and verified the newer live pair. Any pending
# pair is from an earlier interrupted issuance and must not replace this pair
# during startup recovery, even if the consumer reload below is interrupted.
rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"

/usr/bin/reload-certificates.sh "${PROFILE}"
save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
