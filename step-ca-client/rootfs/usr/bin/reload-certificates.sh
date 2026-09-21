#!/command/with-contenv bashio
# shellcheck shell=bash
# ==============================================================================
# Home Assistant Add-on: step-ca-client
#
# step-ca-client add-on for Home Assistant.
# This reloads the certificate in the Home Assistant web server and the addons
# that use the certificates.
# Currently there is no way to reload the certificates on the fly, so a
# full restart of core is required. It is a PR away...
# Ideally a way to reload the certificates on modification has to be found.
# ==============================================================================
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh

CERTFILE="$(ssl_file_path 'certfile')"


# ------------------------------------------------------------------------------
# SAN Verification Logic
# ------------------------------------------------------------------------------

# 1. Get Configured SANs: Remove empty lines, sort alphabetically
CONFIG_SANS=$(bashio::config 'subjects' | sed '/^$/d' | sort)

# 2. Get Certificate SANs: We use '.names[]' which includes CN + SANs
CERT_SANS=$(step certificate inspect "${CERTFILE}" --format json | jq -r '.names[]' | sort)

if [ "$CONFIG_SANS" != "$CERT_SANS" ]; then
    bashio::log.warning "---------------------------------------------------"
    bashio::log.warning "CERTIFICATE MISMATCH DETECTED!"
    bashio::log.warning "The generated certificate does not match configured SANs."
    bashio::log.warning ""
    # Flatten output for logging
    bashio::log.warning "Add-on configured SANs: $(echo "$CONFIG_SANS" | tr '\n' ' ')"
    bashio::log.warning "Certificate SANs: $(echo "$CERT_SANS" | tr '\n' ' ')"
    bashio::log.warning "---------------------------------------------------"
else
    bashio::log.info "Certificate verified: SANs match configuration."
fi
# ------------------------------------------------------------------------------


bashio::log.notice "Services need to be restarted so new certificates are loaded"
bashio::log.info "Restarting will be delayed 5m to avoid losing connectivity on add-on start"
bashio::log.info "If you want to force it, you can always restart this add-on and do it manually"
bashio::log.info "The add-on will not try to restart again until a new renewal is completed"
sleep 300

ADDONS="$(bashio::config 'restart_addons')"
if [ -n "${ADDONS}" ]; then
    bashio::log.warning "Restarting specified addons..."
    while IFS= read -r addon; do
        (bashio::addon.restart "$addon" && bashio::log.info "Addon $addon restarted") \
        || bashio::log.error "Failed to restart $addon"
    done <<< "${ADDONS}"
fi


RESTART_HA="$(bashio::config 'restart_ha')"
if ${RESTART_HA}; then
    bashio::log.warning "Restarting Home Assistant core..."
    (bashio::core.restart && bashio::log.info "Home Assistant core restarted") \
    || bashio::log.error "Failed to restart Home Assistant core"
fi

bashio::log.notice "Finished with the restarts"
