#!/command/with-contenv bashio
# shellcheck shell=bash
set -e

# shellcheck source=/dev/null
source /usr/bin/helpers.sh

PROFILE="${1:-server}"
CERTFILE="$(profile_ssl_file_path "${PROFILE}" certfile)"
if [[ "${PROFILE}" == server ]]; then
    CONFIG_SANS="$(bashio::config 'subjects' | sed '/^$/d' | sort)"
else
    CONFIG_SANS="$(printf '%s\n%s\n' "$(profile_config client subject)" "$(profile_config client sans)" | sed '/^$/d' | sort)"
fi
CERT_SANS="$(step certificate inspect "${CERTFILE}" --format json | jq -r '.names[]' | sort)"
if [[ "${CONFIG_SANS}" != "${CERT_SANS}" ]]; then
    bashio::log.warning "${PROFILE} certificate SANs do not match its configured subject/SANs"
else
    bashio::log.info "${PROFILE} certificate verified: SANs match configuration."
fi

ADDONS="$(profile_config "${PROFILE}" restart_addons)"
RESTART_HA="$(profile_config "${PROFILE}" restart_ha)"
if [[ -z "${ADDONS}" && "${RESTART_HA}" != true ]]; then
    bashio::log.info "No ${PROFILE} services are configured to restart; skipping restart delay"
    exit 0
fi

lock_dir='/run/step-ca-client-restart.lock'
while ! mkdir "${lock_dir}" 2>/dev/null; do
    bashio::log.info "Waiting for another certificate profile's restart callback"
    sleep 1
done
unlock() { rmdir "${lock_dir}"; }
trap unlock EXIT
bashio::log.notice "${PROFILE} certificate updated; services restart in 5 minutes"
sleep 300

if [[ -n "${ADDONS}" ]]; then
    while IFS= read -r app; do
        [[ -z "${app}" ]] && continue
        if bashio::var.true "$(bashio::app.installed "${app}")"; then
            (bashio::app.restart "${app}" && bashio::log.info "App ${app} restarted") \
                || bashio::log.error "Failed to restart app ${app}"
        else
            bashio::log.warning "Configured app ${app} is not installed; skipping restart"
        fi
    done <<< "${ADDONS}"
fi
if [[ "${RESTART_HA}" == true ]]; then
    (bashio::core.restart && bashio::log.info "Home Assistant core restarted") \
        || bashio::log.error "Failed to restart Home Assistant core"
fi
