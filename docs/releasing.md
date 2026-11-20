# Releasing

Bump the version and push its tag:

```sh
Scripts/version.sh patch     # or minor or major; commits VERSION and tags it (0.5.2 → v0.5.3)
git push --follow-tags
```

The Release workflow (`.github/workflows/release.yml`) waits for its approver, then runs the
tests and builds the app on a GitHub Mac runner, and only then puts the release certificate on
the runner and signs the app, the recorder and llama.cpp's server with it, for the hardened
runtime (it stops if any of them ends up signed any other way). It zips the app, writes and signs
`latest.json` (`Scripts/sign-manifest.swift`) with the commit subjects since the previous tag as
notes, attaches the zip, `latest.json` and `install.sh` to a new GitHub release, and checks the
public feed serves them. It stops if the tag doesn't match `VERSION`. Running it by hand from the
Actions tab builds and signs without releasing.

Who can release is settled on GitHub, not in the workflow file:

- The job runs in the **release** environment, which holds the secrets below, lets itself be
  used only from `trunk` and from `v*` tags, and waits for a named approver before it starts. A
  branch can change its own copy of the workflow, but it can't read the secrets or sign anything.
- A ruleset keeps `v*` tags from being made, moved or deleted by anyone but the repository's
  admins.
- The install line fetches `install.sh` from the latest release, so what it runs was approved
  with that release. The copy on `trunk` is the next release's.
- Every pull request is built and tested by the Test workflow (`.github/workflows/test.yml`),
  which has no secrets.

The release environment needs three secrets:

- `OATCAKE_SIGNING_P12` and `OATCAKE_SIGNING_P12_PASSWORD`: the "Oatcake Release" code-signing
  identity (a self-signed certificate valid until 2046), base64-encoded `.p12` and its password.
  It isn't from Apple, so it doesn't satisfy Gatekeeper; what matters is that every release
  carries the same one, so permissions survive updates and installed copies accept the next
  release.
- `OATCAKE_UPDATE_KEY`: the Ed25519 private key that signs `latest.json` (base64 PKCS#8 DER).
  `swift Scripts/sign-manifest.swift keygen` makes a new pair.

Keep copies of the certificate and the update key somewhere safe outside GitHub (secrets can't be
read back). If the certificate is lost, installed copies won't accept releases signed with a new
one and need the install line once. To replace the update key, add the new public key to
`Update.publicKeys`, release, and only then sign with the new key.

To build release-signed copies locally (so a rebuilt recorder keeps its permissions), import the
`.p12` into your login keychain; `Scripts/bundle.sh` then uses it. To try an update before
publishing it, serve a folder holding a zip and its `latest.json` and start Oatcake with
`OATCAKE_UPDATE_FEED=http://127.0.0.1:8000/latest.json`; `install.sh` takes `OATCAKE_FEED` the
same way. With either, the zip is fetched from beside the manifest.

The environment variables for trying a build are in [Development](development.md#trying-a-build).
