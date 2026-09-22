#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This sets up the root CA in the addon.
# ==============================================================================
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh
set_debug

PROFILE="${1:-server}"
bashio::log.info "Setting up Root CA authority for ${PROFILE} certificate profile"

URL="$(profile_ca_url "${PROFILE}")"
FINGERPRINT="$(profile_root_ca_fingerprint "${PROFILE}")"
CAFILE="$(profile_ssl_file_path "${PROFILE}" cafile)"
STEPPATH="$(profile_step_path "${PROFILE}")"

# Do not trace this command: bootstrap context and CA details should not be
# mixed between profiles, and debug output is not useful to operators here.
STEPPATH="${STEPPATH}" step ca bootstrap \
    -f \
    --ca-url="$URL" \
    --fingerprint="$FINGERPRINT"

STEPPATH="${STEPPATH}" step ca roots -f "${CAFILE}"
