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

# Shared certificate scripts take a profile name across process boundaries.
# Server settings are top-level options; client settings live in the nested
# client_certificate option. Keep that layout difference in this accessor.
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

function profile_recovery_dir() {
    local profile="$1"
    validate_profile "${profile}"
    printf '/ssl/.step-ca-%s-recovery' "${profile}"
}

function prepare_recovery_dir() {
    local recovery_dir
    recovery_dir="$(profile_recovery_dir "$1")"
    mkdir -p "${recovery_dir}"
    chmod 0700 "${recovery_dir}"
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

function certificate_pair_matches() {
    local cert="$1" key="$2" cert_fingerprint key_fingerprint
    [[ -s "${cert}" && -s "${key}" ]] || return 1
    cert_fingerprint="$(step crypto key fingerprint "${cert}" 2>/dev/null)" || return 1
    key_fingerprint="$(step crypto key fingerprint "${key}" 2>/dev/null)" || return 1
    [[ -n "${cert_fingerprint}" && "${cert_fingerprint}" == "${key_fingerprint}" ]]
}

function certificate_pair_acceptable() {
    local cert="$1" key="$2" step_path="$3"
    certificate_pair_matches "${cert}" "${key}" &&
        step certificate verify "${cert}" -roots="${step_path}/certs/root_ca.crt" >/dev/null 2>&1
}

# Copy through destination-local temporary files. Preserve the source until
# both destination files have been renamed and verified as a matching pair.
function copy_certificate_pair() {
    local source_cert="$1" source_key="$2" dest_cert="$3" dest_key="$4"
    local temp_cert temp_key
    certificate_pair_matches "${source_cert}" "${source_key}" || return 1
    temp_cert="$(mktemp "${dest_cert}.tmp.XXXXXX")"
    temp_key="$(mktemp "${dest_key}.tmp.XXXXXX")"
    cp -- "${source_cert}" "${temp_cert}"
    cp -- "${source_key}" "${temp_key}"
    chmod 0600 "${temp_key}"
    if ! certificate_pair_matches "${temp_cert}" "${temp_key}"; then
        rm -f -- "${temp_cert}" "${temp_key}"
        return 1
    fi
    mv -f -- "${temp_key}" "${dest_key}"
    mv -f -- "${temp_cert}" "${dest_cert}"
    certificate_pair_matches "${dest_cert}" "${dest_key}"
}

function save_recovery_pair() {
    local profile="$1" cert="$2" key="$3" recovery_dir
    prepare_recovery_dir "${profile}"
    recovery_dir="$(profile_recovery_dir "${profile}")"
    copy_certificate_pair "${cert}" "${key}" \
        "${recovery_dir}/certificate.pem" "${recovery_dir}/key.pem"
}

function cleanup_recovery_artifacts() {
    local certfile="$1" keyfile="$2" recovery_dir="$3" path
    for path in "${certfile}".rollback.* "${certfile}".tmp.* \
        "${keyfile}".rollback.* "${keyfile}".tmp.* \
        "${recovery_dir}"/*.tmp.*; do
        if [[ -e "${path}" || -L "${path}" ]]; then rm -f -- "${path}"; fi
    done
    if [[ ! -s "${recovery_dir}/pending-certificate.pem" ||
        ! -s "${recovery_dir}/pending-key.pem" ]]; then
        rm -f -- "${recovery_dir}/pending-certificate.pem" "${recovery_dir}/pending-key.pem"
    fi
    if [[ ! -s "${recovery_dir}/certificate.pem" ||
        ! -s "${recovery_dir}/key.pem" ]]; then
        rm -f -- "${recovery_dir}/certificate.pem" "${recovery_dir}/key.pem"
    fi
}
