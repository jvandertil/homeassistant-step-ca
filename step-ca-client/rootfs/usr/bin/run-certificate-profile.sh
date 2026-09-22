#!/command/with-contenv bashio
# shellcheck shell=bash
# Bootstrap, issue when necessary, and supervise one certificate profile.
# Each profile is run by its own s6 service so their renewal failures and
# backoff cycles remain independent.
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh
set_debug

PROFILE="${1:?Certificate profile is required}"
validate_profile "${PROFILE}"

if [[ "${PROFILE}" == client ]] && ! client_certificate_enabled; then
    bashio::log.info "Client certificate profile is disabled"
    exec sleep infinity
fi

validate_client_certificate_profile
validate_ssl_file_names

bashio::log.info "Starting ${PROFILE} certificate profile"
/usr/bin/root-ca.sh "${PROFILE}"

CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
STEPPATH="$(profile_step_path "${PROFILE}")"
if ! step certificate verify \
    "${CERTFILE}" -roots="${STEPPATH}/certs/root_ca.crt"; then
    /usr/bin/create-with-token.sh "${PROFILE}"
fi

exec /usr/bin/renewal-daemon.sh "${PROFILE}"
