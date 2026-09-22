#!/command/with-contenv bashio
# shellcheck shell=bash
# Bootstrap, issue when necessary, and supervise one certificate profile.
# Each profile is run by its own s6 service so their renewal failures and
# backoff cycles remain independent.
set -e
umask 077

# shellcheck source=/dev/null
source /usr/bin/helpers.sh
set_debug

PROFILE="${1:?Certificate profile is required}"
validate_profile "${PROFILE}"

if [[ "${PROFILE}" == client ]] && ! client_certificate_enabled; then
    bashio::log.info "Client certificate profile is disabled"
    exec sleep infinity
fi

if [[ "${PROFILE}" == client ]]; then
    validate_client_certificate_profile
fi
validate_ssl_file_names

bashio::log.info "Starting ${PROFILE} certificate profile"
/usr/bin/root-ca.sh "${PROFILE}"

CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
STEPPATH="$(profile_step_path "${PROFILE}")"
RECOVERY_DIR="$(profile_recovery_dir "${PROFILE}")"
RECOVERY_CERT="${RECOVERY_DIR}/certificate.pem"
RECOVERY_KEY="${RECOVERY_DIR}/key.pem"
PENDING_CERT="${RECOVERY_DIR}/pending-certificate.pem"
PENDING_KEY="${RECOVERY_DIR}/pending-key.pem"
mkdir -p "${RECOVERY_DIR}"
chmod 0700 "${RECOVERY_DIR}"
cleanup_recovery_artifacts "${CERTFILE}" "${KEYFILE}" "${RECOVERY_DIR}"

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
    copy_certificate_pair "${CERTFILE}" "${KEYFILE}" "${RECOVERY_CERT}" "${RECOVERY_KEY}"
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
elif certificate_pair_acceptable "${PENDING_CERT}" "${PENDING_KEY}" "${STEPPATH}"; then
    bashio::log.warning "Recovering pending ${PROFILE} certificate issuance"
    copy_certificate_pair "${PENDING_CERT}" "${PENDING_KEY}" "${CERTFILE}" "${KEYFILE}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
    copy_certificate_pair "${CERTFILE}" "${KEYFILE}" "${RECOVERY_CERT}" "${RECOVERY_KEY}"
    rm -f -- "${PENDING_CERT}" "${PENDING_KEY}"
elif certificate_pair_acceptable "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${STEPPATH}"; then
    bashio::log.warning "Restoring ${PROFILE} certificate from recovery"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
    /usr/bin/reload-certificates.sh "${PROFILE}"
elif certificate_pair_matches "${CERTFILE}" "${KEYFILE}"; then
    bashio::log.warning "${PROFILE} active certificate has an invalid or expired chain"
elif certificate_pair_matches "${RECOVERY_CERT}" "${RECOVERY_KEY}"; then
    bashio::log.warning "Restoring structurally matching ${PROFILE} recovery pair"
    copy_certificate_pair "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${CERTFILE}" "${KEYFILE}"
else
    rm -f -- "${RECOVERY_CERT}" "${RECOVERY_KEY}" "${PENDING_CERT}" "${PENDING_KEY}"
fi

if ! certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
    /usr/bin/create-with-token.sh "${PROFILE}"
fi

exec /usr/bin/renewal-daemon.sh "${PROFILE}"
