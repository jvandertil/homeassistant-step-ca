#!/command/with-contenv bashio
# shellcheck shell=bash
# Promote a renewed staged certificate only after it validates against the
# profile's isolated CA context. Live files are replaced atomically.
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh

PROFILE="${1:-server}"
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
KEYFILE="$(profile_ssl_file_path "${PROFILE}" keyfile)"
STEPPATH="$(profile_step_path "${PROFILE}")"
STAGE_DIR="/tmp/step-ca-${PROFILE}-active"
STAGE_CERT="${STAGE_DIR}/certificate.pem"
STAGE_KEY="${STAGE_DIR}/key.pem"

test -s "${STAGE_CERT}" && test -s "${STAGE_KEY}"
step certificate verify "${STAGE_CERT}" \
    -roots="${STEPPATH}/certs/root_ca.crt"

promote_certificate_pair "${STAGE_CERT}" "${STAGE_KEY}" "${CERTFILE}" "${KEYFILE}"
/usr/bin/reload-certificates.sh "${PROFILE}"
