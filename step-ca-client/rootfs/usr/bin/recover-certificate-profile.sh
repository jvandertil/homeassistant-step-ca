#!/command/with-contenv bashio
# shellcheck shell=bash
# Recover a certificate profile whose live pair failed startup validation.
set -e
umask 077

# shellcheck source=/dev/null
source /usr/bin/helpers.sh

PROFILE="${1:?Certificate profile is required}"
validate_profile "${PROFILE}"
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
STEPPATH="$(profile_step_path "${PROFILE}")"
RECOVERY_DIR="$(profile_recovery_dir "${PROFILE}")"
RECOVERY_CERT="${RECOVERY_DIR}/certificate.pem"
RECOVERY_KEY="${RECOVERY_DIR}/key.pem"
PENDING_CERT="${RECOVERY_DIR}/pending-certificate.pem"
PENDING_KEY="${RECOVERY_DIR}/pending-key.pem"

prepare_recovery_dir "${PROFILE}"
cleanup_recovery_artifacts "${CERTFILE}" "${KEYFILE}" "${RECOVERY_DIR}"

# Startup calls this script only when the live pair is unacceptable. Prefer a
# valid pending issuance, then the rolling recovery copy. Keep a matching but
# untrusted pair only so normal startup can fall back to token issuance.
pending_usable=false
recovery_usable=false
if certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}"; then
    pending_usable=true
fi
if certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}"; then
    recovery_usable=true
fi

if [[ "${pending_usable}" == true ]]; then
    bashio::log.warning "Installing pending ${PROFILE} certificate issuance during startup"
    copy_certificate_pair "${PENDING_CERT}" "${PENDING_KEY}" "${CERTFILE}" "${KEYFILE}"
    certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
    save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
    exit 0
fi

if [[ "${recovery_usable}" == true ]]; then
    bashio::log.warning "Restoring ${PROFILE} certificate from recovery"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
    certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
    exit 0
fi

# No usable pair remains. Preserve a matching live pair, including its private
# key; restore a matching recovery pair only when the live pair is broken.
# Both paths still require token issuance because their chains are untrusted.
if certificate_pair_matches "${CERTFILE}" "${KEYFILE}"; then
    bashio::log.warning "${PROFILE} active certificate has an invalid or expired chain"
elif certificate_pair_matches "${RECOVERY_CERT}" "${RECOVERY_KEY}"; then
    bashio::log.warning "Restoring structurally matching ${PROFILE} recovery pair"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
else
    rm -f -- "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${PENDING_CERT}" "${PENDING_KEY}"
fi
