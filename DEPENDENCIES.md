# Dependency policy

The add-on uses Alpine's maintained `step-cli` package. It does not build or
vendor Smallstep software itself.

`step-ca-client/Dockerfile` pins the exact APK version in
`STEP_CLI_VERSION`. Builds therefore fail if that version is unavailable,
instead of silently consuming a newer package.

To update `step-cli`:

1. Check the Alpine package page and upstream Smallstep release notes for the
   candidate version and verify it is available for both `aarch64` and `x86_64`.
1. Change `STEP_CLI_VERSION` in the Dockerfile in its own pull request.
1. Build and smoke-test both supported architectures, including issuance and
   renewal with the existing private key.
1. Record the package version in the pull request and release notes.

Security updates follow the same process and are prioritised. Do not use an
unversioned `apk add step-cli` in release builds.
