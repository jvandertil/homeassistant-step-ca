#!/command/with-contenv bashio
# shellcheck shell=bash
# Reconcile live, pending, and rolling certificate pairs after CA bootstrap.
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

# A valid live pair wins. A valid pending pair with the same certificate marks
# issuance interrupted after installation but before restart handling.
if certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
    if certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}" &&
        [[ "$(step certificate fingerprint "${CERTFILE}")" == "$(step certificate fingerprint "${PENDING_CERT}")" ]]; then
        bashio::log.warning "Completed ${PROFILE} token issuance found during startup; reloading consumers"
        /usr/bin/reload-certificates.sh "${PROFILE}"
    elif certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}" &&
        [[ "$(step certificate fingerprint "${CERTFILE}")" != "$(step certificate fingerprint "${RECOVERY_CERT}")" ]]; then
        bashio::log.warning "Completed ${PROFILE} renewal found during startup; reloading consumers"
        /usr/bin/reload-certificates.sh "${PROFILE}"
    fi
    save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
    exit 0
fi

# A pending token issuance is preferred to the older recovery copy.
if certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}"; then
    bashio::log.warning "Recovering pending ${PROFILE} certificate issuance"
    copy_certificate_pair "${PENDING_CERT}" "${PENDING_KEY}" "${CERTFILE}" "${KEYFILE}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
    save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
    exit 0
fi

if certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}"; then
    bashio::log.warning "Restoring ${PROFILE} certificate from recovery"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
    exit 0
fi

# An expired but matching pair can still serve as the basis for the normal
# verification and token fallback. Prefer the live pair if both are matching.
if certificate_pair_matches "${CERTFILE}" "${KEYFILE}"; then
    bashio::log.warning "${PROFILE} active certificate has an invalid or expired chain"
elif certificate_pair_matches "${RECOVERY_CERT}" "${RECOVERY_KEY}"; then
    bashio::log.warning "Restoring structurally matching ${PROFILE} recovery pair"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
else
    rm -f -- "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${PENDING_CERT}" "${PENDING_KEY}"
fi
