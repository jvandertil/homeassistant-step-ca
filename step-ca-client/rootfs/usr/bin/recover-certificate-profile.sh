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

# Recovery decision tree, in priority order:
# 1. A usable pending issuance wins; install/confirm it, reload consumers, and
#    make it the new rolling recovery copy.
# 2. Otherwise keep a usable live pair. If it differs from the rolling copy,
#    retry the consumer reload before refreshing that copy.
# 3. Otherwise restore a usable rolling recovery pair.
# 4. If no pair has a trusted chain, keep a structurally matching live pair,
#    or restore a structurally matching recovery pair, for normal startup's
#    verification and token fallback. If neither matches, discard the stale
#    recovery state so startup can create a fresh pair.
# "Usable" below means the certificate and key match and the chain verifies;
# "structurally matching" means only that the certificate matches the key.

# A complete pending issuance must be installed before accepting the live
# files. The live pair can still be a valid older certificate if the app was
# interrupted after issuance but before copying the new pair into /ssl.
if certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}"; then
    if certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}" &&
        [[ "$(step certificate fingerprint "${CERTFILE}")" == "$(step certificate fingerprint "${PENDING_CERT}")" ]]; then
        bashio::log.warning "Completed pending ${PROFILE} issuance found during startup; reloading consumers"
    else
        bashio::log.warning "Installing pending ${PROFILE} certificate issuance during startup"
        copy_certificate_pair "${PENDING_CERT}" "${PENDING_KEY}" "${CERTFILE}" "${KEYFILE}"
        certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"
    fi
    /usr/bin/reload-certificates.sh "${PROFILE}"
    save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
    exit 0
fi

# No usable pending issuance remains. A valid live pair wins over the rolling
# copy. A difference from that copy means installation completed before
# restart handling was interrupted, so retry the consumer reload.
if certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
    if certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}" &&
        [[ "$(step certificate fingerprint "${CERTFILE}")" != "$(step certificate fingerprint "${RECOVERY_CERT}")" ]]; then
        bashio::log.warning "Completed ${PROFILE} renewal found during startup; reloading consumers"
        /usr/bin/reload-certificates.sh "${PROFILE}"
    fi
    save_recovery_pair "${PROFILE}" "${CERTFILE}" "${KEYFILE}"
    exit 0
fi

if certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}"; then
    bashio::log.warning "Restoring ${PROFILE} certificate from recovery"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
    exit 0
fi

# Neither pending, live, nor rolling recovery pair has a trusted chain. An
# expired or otherwise untrusted but matching pair can still be checked by
# normal startup and used for token fallback. Prefer the live pair if both
# are structurally matching; restore the rolling copy only if live is broken.
if certificate_pair_matches "${CERTFILE}" "${KEYFILE}"; then
    bashio::log.warning "${PROFILE} active certificate has an invalid or expired chain"
elif certificate_pair_matches "${RECOVERY_CERT}" "${RECOVERY_KEY}"; then
    bashio::log.warning "Restoring structurally matching ${PROFILE} recovery pair"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
else
    rm -f -- "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${PENDING_CERT}" "${PENDING_KEY}"
fi
