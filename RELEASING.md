# Release process

This repository publishes immutable, multi-architecture app images to GitHub
Container Registry (GHCR). The Home Assistant Supervisor reads `image` and
`version` from `step-ca-client/config.yaml` and pulls the image with that exact
version tag.

## Branches

- `main` is the stable channel. Users add
  `https://github.com/jvandertil/homeassistant-step-ca`.
- `develop` is the prerelease channel. Testers add
  `https://github.com/jvandertil/homeassistant-step-ca#develop`.

Do not install both channels on the same Home Assistant instance: they expose
the same `step-ca-client` slug.

## Prerelease

1. Create `develop` from `main` once (`git switch -c develop`), commit the
   branch setup, and push it (`git push -u origin develop`). Then make release
   candidates on `develop`.
1. Set `version` in `step-ca-client/config.yaml` to a unique Semantic Version
   prerelease, for example `0.1.0-beta.1`, and retain `stage: experimental`.
1. Run the repository checks and test the app. For full Supervisor testing,
   use Home Assistant's local-app development environment or a separate test
   instance.
1. Commit and push `develop`.
1. Create and push an annotated tag whose name exactly equals `version`:
   `git tag -a 0.1.0-beta.1 -m "0.1.0-beta.1"`; then
   `git push origin 0.1.0-beta.1`.
1. Wait for the **Publish release image** workflow. It validates the version,
   pushes `amd64` and `aarch64` images, and publishes the GHCR multi-architecture
   manifest `ghcr.io/jvandertil/ha-step-ca-client:0.1.0-beta.1`.
1. Create a GitHub **pre-release** for that existing tag. Its notes are the
   user-facing changelog; it does not build the image.

Never move or reuse a version tag. A Home Assistant installation may already
be using the image it identifies.

After the first successful publish, verify in GitHub **Packages** that the
`ha-step-ca-client` container package is public. The Home Assistant Supervisor
pulls it without GitHub credentials, so it cannot install a private GHCR image.

## Stable release

1. Merge the tested release candidate into `main`.
1. Change `version` to the final unique version (for example `0.1.0`) and set
   `stage: stable`; commit and push that change to `main`.
1. Tag and push that exact `main` commit, wait for the publish workflow, then
   create the GitHub release and release notes.

The tag push builds and publishes the image. The GitHub release is deliberately
last: it documents a version that users can already install.
