# Home Assistant Add-on: step-ca-client

[![Github Actions][github-actions-shield]][github-actions]
[![License][license-shield]](LICENSE.md)

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

## Testing prereleases

Prerelease builds are published from the `develop` branch. To add that channel
in Home Assistant, add the repository URL with `#develop` appended:

`https://github.com/jvandertil/homeassistant-step-ca#develop`

Use either the stable or prerelease repository on one Home Assistant instance;
both provide the same app slug. A prerelease is published to GHCR when its
version tag is pushed. See [the release process](RELEASING.md) for details.

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

[addon-add-repo]: https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fjvandertil%2Fhomeassistant-step-ca
[addon-add-repo-badge]: https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg
[addon-example]: https://github.com/hassio-addons/addon-example
[commits]: https://github.com/jvandertil/homeassistant-step-ca/commits/main
[contributors]: https://github.com/jvandertil/homeassistant-step-ca/graphs/contributors
[docs]: https://github.com/jvandertil/homeassistant-step-ca/blob/main/step-ca-client/DOCS.md
[github-actions-shield]: https://github.com/jvandertil/homeassistant-step-ca/workflows/CI/badge.svg
[github-actions]: https://github.com/jvandertil/homeassistant-step-ca/actions
[license-shield]: https://img.shields.io/github/license/jvandertil/homeassistant-step-ca.svg
[maintainer]: https://github.com/jvandertil
[pki-guide]: https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/
[pki-guide-yubikey]: https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/
[step-ca]: https://smallstep.com/docs/step-ca/installation
