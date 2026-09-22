# Contributing

Contributions are welcome. For substantial changes, please open an issue first
so the proposed approach can be discussed.

## Certificate profile runtime

The app has two certificate profiles: `server` always runs, and `client` runs
when `client_certificate.enabled` is true. Each has its own s6 service, Step CLI
state, renewal loop, and recovery files. A failure or retry in one profile does
not stop the other profile's loop.

The service starts `run-certificate-profile.sh` with the profile name. That
script passes the name to the shared bootstrap, recovery, issuance, and renewal
scripts. They are separate shell processes, so they cannot share an in-memory
configuration object. Each reads the settings it needs through `profile_config`
in `helpers.sh`: server settings are top-level options, while client settings
are under `client_certificate`. The renewal daemon reads its settings once
before its loop. Restart the app to apply certificate configuration changes.

## Issues and feature requests

You've found a bug in the source code, a mistake in the documentation or maybe
you'd like a new feature? You can help us by submitting an issue to our
[GitHub Repository][github]. Before you create an issue, make sure you search
the archive, maybe your question was already answered.

Even better: You could submit a pull request with a fix / new feature!

## Pull request process

1. Search our repository for open or closed [pull requests][prs] that relates
   to your submission. You don't want to duplicate effort.

1. A maintainer will review and merge accepted pull requests.

[github]: https://github.com/jvandertil/homeassistant-step-ca/issues
[prs]: https://github.com/jvandertil/homeassistant-step-ca/pulls
