# Repository guide

## Scope

This repository contains a Home Assistant app (formerly an add-on) that uses
`step-cli` to issue and renew TLS certificates. The runtime is implemented in
Bash under `step-ca-client/rootfs/usr/bin` and runs in a constrained Alpine
container with Home Assistant's Bashio helpers.

## Safety rules

- Treat all values from `bashio::config` as untrusted input. Quote expansions
  and validate filenames before building paths below `/ssl`.
- Never enable `set -x` around tokens, private keys, Supervisor credentials, or
  commands which include them. Add-on logs are visible to Home Assistant users.
- Preserve the private key when changing renewal behaviour unless the user has
  explicitly selected rekeying. Write certificate material safely so a failed
  issuance cannot leave an empty or mismatched certificate/key pair.
- Keep the add-on's Supervisor permissions as narrow as possible. Restarting
  Core or other apps requires the `manager` role and is an intentional security
  trade-off.

## Workflow

- Run `shellcheck` on every modified shell script when it is available.
- Validate `config.yaml` and translation changes with `yamllint` when it is
  available.
- Do not update the `step-cli` package or Home Assistant base image without
  checking its release notes and supported architectures.
- Keep `DOCS.md`, `translations/en.yaml`, and `config.yaml` aligned whenever
  an option changes.

## Home Assistant entities

An app does not itself create Home Assistant entities. Certificate telemetry
should be provided by either MQTT Discovery or a companion custom integration;
prefer a companion integration when no MQTT broker is guaranteed.
