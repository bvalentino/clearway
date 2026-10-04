# Releasing

Clearway is distributed outside the Mac App Store, so Release builds must be signed with a Developer ID Application certificate and notarized by Apple. Auto-updates ship via [Sparkle](https://sparkle-project.org) and are signed with an EdDSA keypair.

## One-time setup

1. **Developer ID Application certificate** — in your login keychain. Verify:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. **App Store Connect API key** — generate at [App Store Connect → Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api) with the **Developer** role. Download the `.p8` once (Apple won't let you download it again) and store it outside the repo:
   ```bash
   mkdir -p ~/.appstoreconnect && chmod 700 ~/.appstoreconnect
   mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/
   chmod 600 ~/.appstoreconnect/AuthKey_*.p8
   ```
   Note the Key ID (10-char) and Issuer ID (UUID) from the same page.

3. **Sparkle private key** — generate with Sparkle's bundled `generate_keys` (shipped under `~/Library/Developer/Xcode/DerivedData/Clearway-*/SourcePackages/artifacts/sparkle/Sparkle/bin/` after the first `./scripts/build.sh` run), export to a file, and `chmod 600`:
   ```bash
   .../bin/generate_keys --account clearway
   .../bin/generate_keys --account clearway -x ~/.sparkle/clearway_ed25519_priv
   chmod 600 ~/.sparkle/clearway_ed25519_priv
   ```
   Rotating the key also requires updating `SUPublicEDKey` in `project.yml` and shipping a new build before any update signed with the new key will be accepted.

4. **Export the environment variables** (add to `~/.zshrc`):
   ```bash
   export ASC_API_KEY_PATH=~/.appstoreconnect/AuthKey_<YOUR_KEY_ID>.p8
   export ASC_API_KEY_ID=<YOUR_KEY_ID>
   export ASC_API_ISSUER_ID=<YOUR_ISSUER_UUID>
   export SPARKLE_PRIVATE_KEY_PATH=~/.sparkle/clearway_ed25519_priv
   ```
   All four are required — the release scripts refuse to run if any are unset.

## Release flow

From a clean `main` that matches `origin/main`, run one command (wall-clock dominated by the Release build and one notary round-trip):

```bash
./scripts/release.sh
```

It asks for the new `MARKETING_VERSION`, then runs unattended until a single `Publish v<VERSION>? [y/N]` prompt. Nothing leaves the machine before that prompt is answered with `y`.

| Step | Script | What it does |
| --- | --- | --- |
| Preflight | `scripts/release.sh` | On `main`, no uncommitted tracked changes, in sync with `origin/main`, the four environment variables set, `gh` logged in, tag `v<VERSION>` not taken |
| Bump | `scripts/release.sh` | Sets `MARKETING_VERSION`, increments `CURRENT_PROJECT_VERSION`, regenerates the xcodeproj, commits `Release v<VERSION>` locally |
| Build | `scripts/release/build.sh` | Clean signed Release build of that commit → `release/Clearway-<VERSION>-<sha>.zip` |
| Package | `scripts/release/package.sh` | DMG → sign → notarize → staple → Gatekeeper check → `release/Clearway-<VERSION>-<sha>.dmg` |
| Publish | `scripts/release/publish.sh` | Re-verifies the DMG, signs it for Sparkle, fetches GitHub's auto-generated notes, shows a summary and asks. On `y`: pushes the release commit, creates the GitHub release (tagged at that commit) with both DMGs, then commits and pushes `docs/appcast.xml` as `Publish v<VERSION> appcast` |

The version bump is committed before the build, so the hash stamped into the app, the artifact names and the `v<VERSION>` tag all refer to the same commit. The appcast is pushed last, so the feed never advertises a DMG that is not downloadable yet. The appcast item embeds a trimmed Markdown copy of the notes so Sparkle's update dialog lists the changes inline; the full text is saved to `release/v<VERSION>-notes.md`.

### Resuming after a failed stage

A failed stage rolls nothing back, and `release.sh` prints the stages still to run. Fix the cause and run them directly, in order — each finds the previous stage's output by `<VERSION>-<sha>`:

```bash
./scripts/release/build.sh
./scripts/release/package.sh
./scripts/release/publish.sh
```

Do not re-run `./scripts/release.sh` to resume: its preflight refuses while the release commit is unpushed, because it would bump the build number a second time. If the fix needs a code change, commit it on top of the release commit and resume from `build.sh`; the artifacts are then named after the new `HEAD`, which is also where the tag goes.

To abandon an unpublished release instead, `git reset --hard origin/main` drops the local release commit.

If `publish.sh` fails after the GitHub release was created, the appcast is the only step left, and re-running `publish.sh` stops at "tag already exists". Delete the release and its tag (`gh release delete v<VERSION> --cleanup-tag`) and run `publish.sh` again.

Both DMGs are uploaded as release assets: the versioned one is fetched by Sparkle via `docs/appcast.xml`, and `Clearway.dmg` keeps the landing page's `/releases/latest/download/Clearway.dmg` URL resolving. Same bytes, same signature.

> **Rollback**: remove or re-point the latest `<item>` in `docs/appcast.xml` and push. New installs and not-yet-updated users get the previous good version. Users who already installed the bad build have to wait for the next release.

## Verifying a build manually

```bash
# DMG
spctl -a -t open --context context:primary-signature -vv release/Clearway-*.dmg
xcrun stapler validate release/Clearway-*.dmg

# Or the .app inside it (needs network — only the DMG carries a stapled ticket)
hdiutil attach -readonly -nobrowse release/Clearway-<VERSION>-<sha>.dmg
codesign -dvv /Volumes/Clearway/Clearway.app
spctl -a -vv /Volumes/Clearway/Clearway.app
hdiutil detach /Volumes/Clearway
```

Both `spctl` calls should report `accepted, source=Notarized Developer ID`.

## Troubleshooting

If `package.sh` reports `status=Invalid`, it auto-fetches and prints the `notarytool` log. Common causes:

- **"The signature does not include a secure timestamp"** — `OTHER_CODE_SIGN_FLAGS = --timestamp` missing from the Release config in `project.yml`.
- **"The executable requests the com.apple.security.get-task-allow entitlement"** — `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` missing from the Release config of the target that builds the named executable (`Clearway` and `ClearwayCLI` both need it). Xcode injects `get-task-allow=true` by default; disabling injection leaves only the target's own entitlements.
- **New hardened runtime exception needed** — `notarytool` names the exact entitlement key; add it to `Clearway.entitlements` and rebuild.

Debug builds (`./scripts/build.sh`, `./scripts/run.sh`) use ad-hoc signing with hardened runtime off, so the dev loop is unaffected.
