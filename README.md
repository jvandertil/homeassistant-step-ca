# Home Assistant Add-on: step-ca-client

[![GitHub Release][releases-shield]][releases]
![Project Stage][project-stage-shield]
[![License][license-shield]](LICENSE.md)

![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

[![Github Actions][github-actions-shield]][github-actions]
![Project Maintenance][maintenance-shield]
[![GitHub Activity][commits-shield]][commits]

## About

This is a [step-ca][step-ca] client add-on for Home Assistant.

It manages the automatic creation and renewal of x509 certificates from a
remote step-ca PKI server, in order to enable TLS/SSL connections in
Home Assistant and the installed addons.

Here is a [quick-start guide][pki-guide] on how to setup step-ca.

With a Yubikey you can even set up setup a [hardware based, local PKI][pki-guide-yubikey].

[:books: Read the full add-on documentation][docs]

## Installation

The installation of this add-on is pretty straightforward and not different
compared to installing any other Home Assistant add-on.

1. First you will need to add the repository to your add-on store with the
   following button:

   [![Add the add-on repository to your Home Assistant instance.][addon-add-repo-badge]][addon-add-repo]

2. Click on add to complete adding the repository.

3. Select **step-ca-client** from the newly added repository and click the
   "Install" button.
4. Configure the add-on in the configuration tab.
5. Start the "step-ca-client" add-on.
6. Check the logs of the "step-ca-client" add-on to see it in action.

## Contributing

This is an active open-source project. We are always open to people who want to
use the code or contribute to it.

We have set up a separate document containing our
[contribution guidelines](.github/CONTRIBUTING.md).

Thank you for being involved! :heart_eyes:

## Authors & contributors

Maintained by [jvandertil][maintainer]. The original add-on was created by
Miguel Angel Nubla and based on Home Assistant's add-on example.

For a full list of all authors and contributors,
check [the contributor's page][contributors].

## License

See [LICENSE.md](LICENSE.md).

[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[addon-add-repo]: https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fjvandertil%2Fhomeassistant-step-ca
[addon-add-repo-badge]: https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg
[addon-example]: https://github.com/hassio-addons/addon-example
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
[commits-shield]: https://img.shields.io/github/commit-activity/y/jvandertil/homeassistant-step-ca.svg
[commits]: https://github.com/jvandertil/homeassistant-step-ca/commits/main
[contributors]: https://github.com/jvandertil/homeassistant-step-ca/graphs/contributors
[docs]: https://github.com/jvandertil/homeassistant-step-ca/blob/main/step-ca-client/DOCS.md
[github-actions-shield]: https://github.com/jvandertil/homeassistant-step-ca/workflows/CI/badge.svg
[github-actions]: https://github.com/jvandertil/homeassistant-step-ca/actions
[license-shield]: https://img.shields.io/github/license/jvandertil/homeassistant-step-ca.svg
[maintenance-shield]: https://img.shields.io/maintenance/yes/2023.svg
[maintainer]: https://github.com/jvandertil
[pki-guide]: https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/
[pki-guide-yubikey]: https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/
[project-stage-shield]: https://img.shields.io/badge/project%20stage-production%20ready-brightgreen.svg
[releases-shield]: https://img.shields.io/github/release/jvandertil/homeassistant-step-ca.svg
[releases]: https://github.com/jvandertil/homeassistant-step-ca/releases
[step-ca]: https://smallstep.com/docs/step-ca/installation
