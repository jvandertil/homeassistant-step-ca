#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# ==============================================================================
set -e

function set_debug() {
    STEPDEBUG=0
    if ! [[ "${__BASHIO_LOG_LEVEL_DEBUG}" -gt "${__BASHIO_LOG_LEVEL}" ]]; then
        STEPDEBUG=1
    fi
    export STEPDEBUG
}

# Return a path below the add-on's mapped SSL directory. Configuration values
# are user-controlled, so do not allow them to select another file in /ssl.
function ssl_file_path() {
    local config_key="$1"
    local filename

    filename="$(bashio::config "${config_key}")"
    if [[ ! "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        bashio::log.fatal \
            "Configuration option '${config_key}' must be a filename without path separators"
        exit 1
    fi

    printf '/ssl/%s' "${filename}"
}

# These outputs are all overwritten by step-cli. Reject collisions before an
# issuance or bootstrap can replace a private key with certificate material.
function validate_ssl_file_names() {
    local cafile certfile keyfile

    cafile="$(ssl_file_path 'cafile')"
    certfile="$(ssl_file_path 'certfile')"
    keyfile="$(ssl_file_path 'keyfile')"

    if [[ "${cafile}" == "${certfile}" || "${cafile}" == "${keyfile}" || "${certfile}" == "${keyfile}" ]]; then
        bashio::log.fatal "cafile, certfile, and keyfile must use different filenames"
        exit 1
    fi
}
