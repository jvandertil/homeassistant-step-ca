# Home Assistant Add-on: step-ca-client

This is an [step-ca][step-ca] client add-on for Home Assistant.

It manages the automatic creation and renewal of x509 certificates from a
remote step-ca PKI server, in order to enable TLS/SSL connections in
Home Assistant and the installed addons.

Here is a [quick-start guide][pki-guide] on how to set up step-ca.

With a Yubikey, you can even set up set up a [hardware-based, local PKI][pki-guide-yubikey].

## Configuration

You will need a one-time token generated with `step ca token` to issue the
certificate, and to keep the addon always running so it renews the certificate
automatically (enable "Start on boot" and "Watchdog" on the add-on
configuration page).

**Note**: Certificates in step-ca have short lifetimes, usually 24 hours, if the addon
is not running and the certificate expires, you must manually generate
a new one-time token.

The certificate lifetime is dictated when creating the token. It will use the
default provisioner lifetime. You can change it with `step ca provisioner update <provisioner-name> --x509-default-dur=<duration>`
_before_ generating the token, but keep in mind [the design decisions of step-ca][passive-revocation].

Example add-on configuration:

```yaml
ca_url: https://tinyca.internal
root_ca_fingerprint: "d9d0978692f1c7cc791f5c343ce98771900721405e834cd27b9502cc719f5097"
token: "692f1c7cc791f5c343ce987d9d0978692f1c7cc791f5c343ce98692f1c7cc791f5c343ce987"
subjects:
  - homeassistant.local
  - mqtt.local
keyfile: privkey.pem
certfile: fullchain.pem
key_type: RSA
renewal_method: renew
renewal_threshold: 66%
retry_backoff_seconds: 60
renewal_check_interval_seconds: 3600
log_level: info
mqtt:
  enabled: false
  instance_id: ""
  host: ""
  port: 1883
  username: ""
  password: ""
  tls: false
  ca_file: ""
  client_cert_file: ""
  client_key_file: ""
client_certificate:
  enabled: false
  # Leave these blank to use the server CA above.
  ca_url: ""
  root_ca_fingerprint: ""
  token: ""
  subject: homeassistant-client
  sans: []
  cafile: client-ca.pem
  keyfile: client-privkey.pem
  certfile: client-fullchain.pem
  key_type: RSA
  renewal_method: renew
  renewal_threshold: 66%
  restart_ha: false
  restart_addons: []
```

### Optional `client_certificate` identity

`client_certificate` manages one reusable client-authentication (mTLS)
certificate and private key under `/ssl`. It is disabled by default and is not
used by Home Assistant or MQTT automatically. Enable it only for a trusted
consumer that you configure separately; every `/ssl` consumer can read this
private key. Do not reuse this shared identity for devices: devices should have
their own identities.

Set `enabled: true`, supply a `token` and non-empty `subject`, and optionally
list `sans`. The token must include the subject and every SAN (`step ca token`
requires matching `--san` flags), just like the server certificate token.

The client uses the server `ca_url` and `root_ca_fingerprint` when its own
values are blank. Supplying both client CA values creates an isolated Step CLI
bootstrap context and `cafile`, so the two profiles can use different issuing
CAs. All six configured file names (both profiles' CA, key, and certificate
files) must be unique filenames relative to `/ssl`.

`key_type`, `renewal_method`, and `renewal_threshold` behave as for the server
certificate. `renew` retains the client private key; `rekey` rotates it. Client
`restart_addons` and `restart_ha` are independent of the server restart
settings and default to no restarts. The Core restart toggle is an explicit
operator-controlled hook only:
current Core integrations may not load a renewable certificate from `/ssl`, and
enabling it does not configure a Core mTLS consumer.

Each profile keeps a rolling recovery copy in `/ssl/.step-ca-server-recovery`
or `/ssl/.step-ca-client-recovery`. These hidden directories are mode `0700`;
their `key.pem` and temporary `pending-key.pem` files are mode `0600` and
contain copies of the private keys.
Protect `/ssl` backups accordingly. The add-on stages renewed material and
verifies the certificate and key before installing them.
On startup it checks certificate and key fingerprints and the CA chain, then
repairs an interrupted write from the recovery copy or completes a pending
token issuance. A valid active renewal completed before its restart callback
is kept and its consumers are restarted. If all available certificates are
expired or invalid, issue a new one-time token manually and restart the add-on.

### Option: `ca_url`

URL of the targeted Step Certificate Authority.

### Option: `root_ca_fingerprint`

The fingerprint of the root certificate.

### Option: `token`

The token generated with `step ca token`.

As mentioned before, it will only be used the first time the addon runs. You can
remove it or keep it for regular operation. If there is ever any problem and the
certificate is not renewed before the expiration date, you will need to generate
a new token manually, configure it here and restart the addon.

The token must be generated with the same subjects configured on the
addon. If only using one, specifying it as the positional argument is enough.

### Option: `subjects`

Add domain names or IP Address as Subjective Alternative Names (SANs) to the
certificate.

Effectively the address you use to access the services you want
to use SSL/TLS with. Some examples:

- For `https://homeassistant.local:8123` use `homeassistant.local`
- For `mqtts://my-mqtt-server.internal` use `my-mqtt-server.internal`,
- For `https://mydomainname.com/hass/` use `mydomainname.com`

**Note**: if you need more than one, you will have to add `--san` arguments for every
one of them when creating the token, including the one you specify as the "principal"
subject. Else some certificate validators will not accept it.

In short, use either:

- `step ca token homeassistant.local` for:
  - `homeassistant.local`
- or `step ca token --san=mqtt.local --san=homeassistant.local homeassistant.local` for:
  - `homeassistant.local`
  - and `mqtt.local`

### Option: `cafile`

Path to where the root CA certificates will be stored relative to `/ssl/`.

### Option: `keyfile`

Path to where the private key file will be created relative to `/ssl/`.

### Option: `certfile`

Path to where the certificate file will be created relative to `/ssl/`.

### Option: `renewal_method`

Controls how the certificate is updated automatically:

- `renew` (default) renews the certificate while retaining the existing private
  key.
- `rekey` generates a new private key and certificate on every scheduled
  update.

Restart the add-on after changing this option. The setting is read when the
renewal loop starts, so changing the add-on configuration does not alter an
already running loop. Rekeying may require certificate-consuming services to
accept the newly generated key; use `renew` unless key rotation is required.

### Option: `renewal_threshold`

When to renew a certificate. The default `66%` means renewal starts after 66%
of the certificate's lifetime has elapsed. Lower percentages renew earlier.
You can instead use a time before expiry, such as `24h`, `90m`, or `1h15m`.
Only percentages or durations in seconds (`s`), minutes (`m`), and hours (`h`)
are accepted. The server and client certificates have independent thresholds;
`renewal_method` determines whether each due update renews or rekeys.

Restart the app after changing this option; the new threshold is checked on
startup. For a temporary early renewal, choose a value that makes the existing
certificate due (for example, `4h` when it expires in 3 hours), then restore
`66%` after it renews. This is an ongoing renewal
policy, so leaving a low percentage or a duration longer than the lifetime of
newly issued certificates can cause frequent repeat renewals.

### Option: `retry_backoff_seconds`

The number of seconds (1–3600, default 60) to wait before restarting the
renewal attempt after a failure. Increase this when the CA is
expected to be unavailable for an extended period; reduce it only when more
frequent retry attempts are acceptable.

### Option: `renewal_check_interval_seconds`

Seconds between healthy checks (1–86400, default 3600). Each profile is
checked on startup with `step certificate needs-renewal` using
`renewal_threshold`. Failed due renewals are retried after
`retry_backoff_seconds`.

### Option: `mqtt`

Optional MQTT Discovery telemetry. Supply a broker and configure Home
Assistant's MQTT integration separately. Set `enabled: true`, a unique
`instance_id` for each installation sharing a broker, and `host` and `port`.
The ID may contain letters, digits, underscores, and hyphens. Username and
password are optional. Set `tls: true` to verify the broker with system trust,
or set `ca_file` to a PEM CA filename under `/ssl`. For broker mTLS, set both
`client_cert_file` and `client_key_file` to PEM filenames under `/ssl`;
these may be the managed client profile files. TLS paths must be single
filenames. TLS files require `tls: true`.

Discovery creates one device with server certificate expiration, renewal due,
renewal failure, and last successful renewal entities. The client profile adds
the same entities when enabled. Renewal failure turns on after a failed due
renewal or rekey attempt and clears after success. Status is published every
five minutes and expires after 15 minutes without updates. The last successful
renewal has no value until the first successful renewal. MQTT does not change
certificate operation. When MQTT is disabled, the app attempts to remove its
retained discovery topics using the current broker settings.

Example expiration alert (replace the entity ID with the discovered one):

```yaml
automation:
  - alias: Step CA server certificate expires soon
    triggers:
      - trigger: template
        value_template: >
          {{ states('sensor.server_expiration') not in ['unknown', 'unavailable']
             and as_timestamp(states('sensor.server_expiration'), 0)
                 < as_timestamp(now()) + 86400 }}
    actions:
      - action: persistent_notification.create
        data:
          title: Certificate expires soon
          message: Check the step-ca-client renewal status.
```

### Option: `restart_ha`

Whether or not to restart Home Assistant core.

Currently there is no way to reload the certificates on the fly, so a
full restart of Home Assistant Core is required.

Enabling this option requires the add-on's `hassio_role: manager` permission.
Home Assistant rates that role as a security trade-off because it grants
extended Supervisor rights. It is retained solely to restart Core after a
successful certificate update; set `restart_ha: false` if automatic Core
restarts are not acceptable in your environment.

### Option: `restart_addons`

List of app IDs that will be restarted when a certificate is renewed. The
default includes the core Mosquitto broker.

Use the app ID shown in the app's URL. For the core Mosquitto broker it is
`core_mosquitto`, which is the default. If a configured app is not installed,
the restart is skipped with a warning.

### Option: `log_level`

The `log_level` option controls the level of log output by the add-on and can
be changed to be more or less verbose, which might be useful when you are
dealing with an unknown issue.

### Option: `key_type`

The key-pair type to generate for the certificate.
Corresponding [step cli documentation][docs-step-ca-certificate-kty] for `--kty`

As of Tasmota v12.4.0, MQTT over TLS will only work with RSA keys, so keep this
as RSA if you plan to use the generated certificate with the MQTT server.
This limitation of tasmota also means that in order to do full chain
verification, all the certificates up to the root ca must have a compatible key
type. RSA is not the default for `step-ca init` when the PKI is created, and
not convenient to change for all the chain if the PKI is going to have more use
cases other than Tasmota.
Until upstream Tasmota adds support for EC keys, the workaround is to use RSA
for this certificate only, have a PKI with the defaults and use `SetOption132 1`
in Tasmota to switch to one-level fingerprint verification as described in Tasmota
[MQTT over TLS documentation][tasmota-mqtt-over-tls].

## Changelog & Releases

This repository keeps a change log using [GitHub's releases][releases]
functionality.

Releases are based on [Semantic Versioning][semver], and use the format
of `MAJOR.MINOR.PATCH`. In a nutshell, the version will be incremented
based on the following:

- `MAJOR`: Incompatible or major changes.
- `MINOR`: Backwards-compatible new features and enhancements.
- `PATCH`: Backwards-compatible bugfixes and package updates.

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

See [LICENSE.md](../LICENSE.md).

[addon-example]: https://github.com/hassio-addons/addon-example
[contributors]: https://github.com/jvandertil/homeassistant-step-ca/graphs/contributors
[docs-step-ca-certificate-kty]: https://smallstep.com/docs/step-cli/reference/ca/certificate#:~:text=token%20generating%20key.-,%2D%2Dkty%3D,-kty
[maintainer]: https://github.com/jvandertil
[pki-guide]: https://smallstep.com/docs/step-ca/getting-started
[pki-guide-yubikey]: https://smallstep.com/blog/build-a-tiny-ca-with-raspberry-pi-yubikey/
[releases]: https://github.com/jvandertil/homeassistant-step-ca/releases
[semver]: http://semver.org/spec/v2.0.0.html
[step-ca]: https://smallstep.com/docs/step-ca/installation
[tasmota-mqtt-over-tls]: https://tasmota.github.io/docs/TLS/
[passive-revocation]: https://smallstep.com/blog/passive-revocation/
