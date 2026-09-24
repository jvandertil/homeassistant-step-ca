#!/command/with-contenv bashio
# shellcheck shell=bash
# Bootstrap, issue when necessary, and supervise one certificate profile.
# Each profile is run by its own s6 service so their renewal failures and
# backoff cycles remain independent. Pass only the profile name to child
# scripts; each process reads the settings it needs through profile_config.
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

if ! certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
    /usr/bin/recover-certificate-profile.sh "${PROFILE}"

    if ! certificate_pair_acceptable "${CERTFILE}" "${KEYFILE}" "${STEPPATH}"; then
        /usr/bin/create-with-token.sh "${PROFILE}"
    fi
fi

exec /usr/bin/renewal-daemon.sh "${PROFILE}"
