#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# ==============================================================================
set -e

# Set STEPDEBUG according to Bashio's configured log level.
# Globals:
#   __BASHIO_LOG_LEVEL
#   __BASHIO_LOG_LEVEL_DEBUG
#   STEPDEBUG (set)
# Arguments:
#   None
function set_debug() {
    STEPDEBUG=0
    if ! [[ "${__BASHIO_LOG_LEVEL_DEBUG}" -gt "${__BASHIO_LOG_LEVEL}" ]]; then
        STEPDEBUG=1
    fi
    export STEPDEBUG
}

# Stop the calling script if the profile is not server or client. This prevents
# an unsupported value from selecting the server configuration by default.
# Arguments:
#   $1: Certificate profile name.
# Returns:
#   0 for a supported profile; exits the calling script otherwise.
function validate_profile() {
    case "$1" in
        server|client) ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

# Read a setting from the selected certificate profile.
# Server settings are top-level options; client settings are nested.
# Arguments:
#   $1: Certificate profile name.
#   $2: Configuration field name.
# Outputs:
#   Writes the configured value to stdout.
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

# Return the configured SSL file path for a profile and field.
# The configured filename must be a basename with no path separators.
# Arguments:
#   $1: Certificate profile name.
#   $2: Configuration field name (cafile, certfile, or keyfile).
# Outputs:
#   Writes the file path below /ssl to stdout.
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

# Return the step-cli configuration directory for a certificate profile.
# Arguments:
#   $1: Certificate profile name.
# Outputs:
#   Writes the profile's step-cli path to stdout.
function profile_step_path() {
    case "$1" in
        server) printf '%s' '/root/.step-server' ;;
        client) printf '%s' '/root/.step-client' ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

# Return the recovery directory for a certificate profile.
# Arguments:
#   $1: Certificate profile name.
# Outputs:
#   Writes the recovery directory path below /ssl to stdout.
function profile_recovery_dir() {
    local profile="$1"
    validate_profile "${profile}"
    printf '/ssl/.step-ca-%s-recovery' "${profile}"
}

# Create the profile recovery directory with owner-only access.
# Arguments:
#   $1: Certificate profile name.
function prepare_recovery_dir() {
    local recovery_dir
    recovery_dir="$(profile_recovery_dir "$1")"
    mkdir -p "${recovery_dir}"
    chmod 0700 "${recovery_dir}"
}

# Return the primary subject configured for a certificate profile.
# Arguments:
#   $1: Certificate profile name.
# Outputs:
#   Writes the primary subject to stdout.
function profile_subject() {
    case "$1" in
        server) bashio::config 'subjects' | head -1 ;;
        client) profile_config client subject ;;
        *) bashio::log.fatal "Unknown certificate profile '$1'"; exit 1 ;;
    esac
}

# Return the configured subjects and subject alternative names for a profile.
# Arguments:
#   $1: Certificate profile name.
# Outputs:
#   Writes one subject or name per line to stdout.
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

# Check whether client certificate issuance is enabled.
# Outputs:
#   Writes no data; returns success when enabled and failure when disabled.
function client_certificate_enabled() {
    [[ "$(profile_config client enabled)" == true ]]
}

# Validate required client profile settings when client issuance is enabled.
# Arguments:
#   None
# Returns:
#   0 when settings are valid; exits the calling script if token or subject is
#   missing from an enabled profile.
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

# Return the CA URL for a profile, falling back to the server URL for clients.
# Arguments:
#   $1: Certificate profile name.
# Outputs:
#   Writes the selected CA URL to stdout.
function profile_ca_url() {
    local profile="$1" value
    value="$(profile_config "${profile}" ca_url)"
    if [[ "${profile}" == client && ( -z "${value}" || "${value}" == null ) ]]; then
        value="$(profile_config server ca_url)"
    fi
    printf '%s' "${value}"
}

# Return the root CA fingerprint for a profile, using the server value as the
# client fallback.
# Arguments:
#   $1: Certificate profile name.
# Outputs:
#   Writes the selected root CA fingerprint to stdout.
function profile_root_ca_fingerprint() {
    local profile="$1" value
    value="$(profile_config "${profile}" root_ca_fingerprint)"
    if [[ "${profile}" == client && ( -z "${value}" || "${value}" == null ) ]]; then
        value="$(profile_config server root_ca_fingerprint)"
    fi
    printf '%s' "${value}"
}

# Validate that configured CA, certificate, and key filenames do not collide.
# step-cli overwrites these paths during issuance and bootstrap.
# Arguments:
#   None
# Returns:
#   0 when filenames are unique; exits the calling script on a collision.
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

# Check that a certificate and private key contain the same public key.
# Arguments:
#   $1: Certificate file path.
#   $2: Private key file path.
# Returns:
#   0 when both files are nonempty and match; nonzero otherwise.
function certificate_pair_matches() {
    local cert="$1" key="$2" cert_fingerprint key_fingerprint
    [[ -s "${cert}" && -s "${key}" ]] || return 1
    cert_fingerprint="$(step crypto key fingerprint "${cert}" 2>/dev/null)" || return 1
    key_fingerprint="$(step crypto key fingerprint "${key}" 2>/dev/null)" || return 1
    [[ -n "${cert_fingerprint}" && "${cert_fingerprint}" == "${key_fingerprint}" ]]
}

# Check that a certificate and key match and that the certificate chain
# verifies.
# Arguments:
#   $1: Certificate file path.
#   $2: Private key file path.
#   $3: step-cli configuration directory containing the trusted root.
# Returns:
#   0 when the pair matches and verifies; nonzero otherwise.
function certificate_pair_acceptable() {
    local cert="$1" key="$2" step_path="$3"
    certificate_pair_matches "${cert}" "${key}" &&
        step certificate verify "${cert}" -roots="${step_path}/certs/root_ca.crt" >/dev/null 2>&1
}

# Copy a matching certificate and key through destination-local temporary files.
# The source remains intact until the installed destination pair is verified.
# Arguments:
#   $1: Source certificate path.
#   $2: Source private key path.
#   $3: Destination certificate path.
#   $4: Destination private key path.
# Returns:
#   0 when the installed pair matches; nonzero if validation or copying fails.
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

# Save a matching certificate and key as the profile's recovery pair.
# Arguments:
#   $1: Certificate profile name.
#   $2: Certificate file path.
#   $3: Private key file path.
# Returns:
#   0 when the recovery pair is saved and verified; nonzero on failure.
function save_recovery_pair() {
    local profile="$1" cert="$2" key="$3" recovery_dir
    prepare_recovery_dir "${profile}"
    recovery_dir="$(profile_recovery_dir "${profile}")"
    copy_certificate_pair "${cert}" "${key}" \
        "${recovery_dir}/certificate.pem" "${recovery_dir}/key.pem"
}

# Remove temporary files and discard incomplete pending or recovery pairs.
# Arguments:
#   $1: Active certificate file path.
#   $2: Active private key file path.
#   $3: Profile recovery directory.
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
