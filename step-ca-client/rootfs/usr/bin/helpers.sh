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

# Fail closed whenever a script is called with an unsupported profile. Without
# this check, an unknown value could accidentally use the server configuration.
function validate_profile() {
    case "$1" in
        server|client) ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

function profile_config() {
    local profile="$1"
    local field="$2"

    case "${profile}" in
        server)
            bashio::config "${field}"
            ;;
        client)
            # Bashio only addresses top-level options. Decode the nested
            # profile explicitly so this also works on Supervisor versions
            # without dotted configuration-key support.
            bashio::config 'client_certificate' | jq -r --arg field "${field}" \
                '.[$field] | if type == "array" then .[] else . end'
            ;;
        *)
            bashio::log.fatal "Unknown certificate profile '${profile}'"
            exit 1
            ;;
    esac
}

function profile_ssl_file_path() {
    local profile="$1"
    local field="$2"
    local config_key filename

    validate_profile "${profile}"
    if [[ "${profile}" == server ]]; then
        config_key="${field}"
    else
        config_key="client_certificate.${field}"
    fi
    filename="$(profile_config "${profile}" "${field}")"
    if [[ ! "${filename}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        bashio::log.fatal \
            "Configuration option '${config_key}' must be a filename without path separators"
        exit 1
    fi
    printf '/ssl/%s' "${filename}"
}

function profile_step_path() {
    case "$1" in
        server) printf '%s' '/root/.step-server' ;;
        client) printf '%s' '/root/.step-client' ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

function profile_stage_dir() {
    local profile="$1"
    local purpose="$2"

    validate_profile "${profile}"
    case "${purpose}" in
        initial|active) ;;
        *) bashio::log.fatal "Unknown certificate staging purpose '${purpose}'"; exit 1 ;;
    esac
    printf '/tmp/step-ca-%s-%s' "${profile}" "${purpose}"
}

function profile_subject() {
    case "$1" in
        server) bashio::config 'subjects' | head -1 ;;
        client) profile_config client subject ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

function profile_sans() {
    case "$1" in
        server) bashio::config 'subjects' ;;
        client)
            printf '%s\n%s\n' \
                "$(profile_config client subject)" \
                "$(profile_config client sans)"
            ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

function client_certificate_enabled() {
    [[ "$(profile_config client enabled)" == true ]]
}

function validate_client_certificate_profile() {
    local field value

    client_certificate_enabled || return 0
    for field in token subject; do
        value="$(profile_config client "${field}")"
        if [[ -z "${value}" || "${value}" == null ]]; then
            bashio::log.fatal "Enabled client certificate profile requires '${field}'"
            exit 1
        fi
    done
}

function profile_ca_url() {
    local profile="$1" value
    value="$(profile_config "${profile}" ca_url)"
    if [[ "${profile}" == client && ( -z "${value}" || "${value}" == null ) ]]; then
        value="$(profile_config server ca_url)"
    fi
    printf '%s' "${value}"
}

function profile_root_ca_fingerprint() {
    local profile="$1" value
    value="$(profile_config "${profile}" root_ca_fingerprint)"
    if [[ "${profile}" == client && ( -z "${value}" || "${value}" == null ) ]]; then
        value="$(profile_config server root_ca_fingerprint)"
    fi
    printf '%s' "${value}"
}

# These outputs are all overwritten by step-cli. Reject collisions before an
# issuance or bootstrap can replace a private key with certificate material.
function validate_ssl_file_names() {
    local profile field path
    local -a paths=()
    local -a profiles=(server)

    validate_client_certificate_profile
    if client_certificate_enabled; then
        profiles+=(client)
    fi
    for profile in "${profiles[@]}"; do
        for field in cafile certfile keyfile; do
            path="$(profile_ssl_file_path "${profile}" "${field}")"
            if [[ " ${paths[*]} " == *" ${path} "* ]]; then
                bashio::log.fatal "Certificate profile filenames must be unique; '${path}' is configured more than once"
                exit 1
            fi
            paths+=("${path}")
        done
    done
}

# Replace the two live files with a staged, verified pair. Two path names
# cannot be atomically swapped together on Linux, so retain copies of the old
# pair and restore both paths if a command or signal interrupts promotion.
function promote_certificate_pair() {
    local staged_cert="$1"
    local staged_key="$2"
    local certfile="$3"
    local keyfile="$4"
    local old_cert='' old_key='' new_cert='' new_key=''
    local had_cert=false had_key=false key_promoted=false cert_promoted=false

    [[ -s "${staged_cert}" && -s "${staged_key}" ]] || return 1
    if [[ -e "${certfile}" ]]; then
        had_cert=true
        old_cert="$(mktemp "${certfile}.rollback.XXXXXX")"
        cp "${certfile}" "${old_cert}"
    fi
    if [[ -e "${keyfile}" ]]; then
        had_key=true
        old_key="$(mktemp "${keyfile}.rollback.XXXXXX")"
        cp "${keyfile}" "${old_key}"
        chmod 0600 "${old_key}"
    fi
    new_key="$(mktemp "${keyfile}.tmp.XXXXXX")"
    new_cert="$(mktemp "${certfile}.tmp.XXXXXX")"
    cp "${staged_key}" "${new_key}"
    chmod 0600 "${new_key}"
    cp "${staged_cert}" "${new_cert}"

    # shellcheck disable=SC2329 # Invoked by the EXIT/HUP/INT/TERM trap below.
    rollback_pair() {
        if [[ "${key_promoted}" == true ]]; then
            if [[ "${had_key}" == true ]]; then mv -f "${old_key}" "${keyfile}"; else rm -f "${keyfile}"; fi
        fi
        if [[ "${cert_promoted}" == true ]]; then
            if [[ "${had_cert}" == true ]]; then mv -f "${old_cert}" "${certfile}"; else rm -f "${certfile}"; fi
        fi
        rm -f "${new_key}" "${new_cert}" "${old_key}" "${old_cert}"
    }
    trap rollback_pair EXIT HUP INT TERM
    mv -f "${new_key}" "${keyfile}"
    key_promoted=true
    mv -f "${new_cert}" "${certfile}"
    cert_promoted=true
    rm -f "${old_key}" "${old_cert}"
    trap - EXIT HUP INT TERM
}
