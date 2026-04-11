# Releasing

Clearway is distributed outside the Mac App Store, so Release builds must be **signed with a Developer ID Application certificate** and **notarized by Apple** for Gatekeeper to open them without warnings.

## One-time setup

1. **Developer ID Application certificate** — In your login keychain. Verify with:
   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
   Should print the identity referenced in `project.yml` (Release config).

2. **App Store Connect API key** — Generate at [App Store Connect → Users and Access → Integrations](https://appstoreconnect.apple.com/access/integrations/api) with the **Developer** role. Download the `.p8` file once (Apple does not let you download it again) and store it outside the repo:
   ```bash
   mkdir -p ~/.appstoreconnect && chmod 700 ~/.appstoreconnect
   mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/
   chmod 600 ~/.appstoreconnect/AuthKey_*.p8
   ```
   From the same page, note the **Key ID** (10-character identifier next to your key) and the **Issuer ID** (UUID at the top of the page). You will need both in step 3.

3. **Export the notarization environment variables** in your shell (add to `~/.zshrc` for persistence):
   ```bash
   export ASC_API_KEY_PATH=~/.appstoreconnect/AuthKey_<YOUR_KEY_ID>.p8
   export ASC_API_KEY_ID=<YOUR_KEY_ID>           # 10-char string, e.g. ABCDE12345
   export ASC_API_ISSUER_ID=<YOUR_ISSUER_UUID>   # UUID from App Store Connect
   ```

   All three are required — `scripts/notarize.sh` and `scripts/package-dmg.sh` will refuse to run if any are unset. They are intentionally not committed to the repo.

4. **Sparkle private key** — Clearway's auto-updates are signed with an EdDSA (ed25519) keypair. The private key lives outside the repo at `~/.sparkle/clearway_ed25519_priv` with mode `600`; the matching public key is embedded into `Info.plist` as `SUPublicEDKey` and ships inside the app. `scripts/publish-update.sh` reads the file via the `SPARKLE_PRIVATE_KEY_PATH` environment variable — export it in your shell alongside the notarization variables above:
   ```bash
   export SPARKLE_PRIVATE_KEY_PATH=~/.sparkle/clearway_ed25519_priv
   ```
   Sparkle's signing CLIs (`sign_update`, `generate_keys`) are shipped as part of the Sparkle SPM package and live under `~/Library/Developer/Xcode/DerivedData/Clearway-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`. `publish-update.sh` locates `sign_update` from there automatically — nothing needs to be installed on `PATH`. Running `./scripts/build.sh` or `./scripts/release.sh` once is enough to populate the artifact bundle. To regenerate the keypair, run `.../bin/generate_keys --account clearway` (it stores the key in your login Keychain), export it to a file with `.../bin/generate_keys --account clearway -x ~/.sparkle/clearway_ed25519_priv`, and `chmod 600` the result. Rotating the key also requires updating `SUPublicEDKey` in `project.yml` and shipping a new build before any update signed with the new key will be accepted.

## Auto-updates (Sparkle)

Clearway ships with [Sparkle](https://sparkle-project.org) for in-app auto-updates. The updater fetches a signed appcast feed at startup (and on demand via *Clearway → Check for Updates…*), downloads the new DMG, verifies its EdDSA signature against the public key embedded in the app, and applies the update.

- **Appcast URL**: `https://bvalentino.github.io/clearway/appcast.xml`. The single source of truth is the `SPARKLE_FEED_URL` build setting in `project.yml`, which is injected into the built `Info.plist` as `SUFeedURL`. Change it in `project.yml` and re-run `xcodegen generate`; do not edit the pbxproj or the Info.plist by hand.
- **Public key (`SUPublicEDKey`)**: injected into the built `Info.plist` by the `Inject Sparkle Info.plist keys` postBuildScript in `project.yml`, sourced from the `SPARKLE_PUBLIC_KEY` build setting. The matching private key story is in step 4 of [One-time setup](#one-time-setup) above.
- **Private key**: lives outside the repo at `~/.sparkle/clearway_ed25519_priv` with mode `600`. See One-time setup step 4 for the full regeneration workflow; the rest of this section assumes the file already exists.
- **Sparkle helpers re-signing**: Sparkle's bundled `Autoupdate`, `Updater.app`, and XPC services are automatically re-signed with the Developer ID by a Release-only build phase, so library validation works without disabling it. No manual intervention required.
- **Publish-time environment variable** read by `scripts/publish-update.sh`:
  ```bash
  export SPARKLE_PRIVATE_KEY_PATH=~/.sparkle/clearway_ed25519_priv
  ```
  Add this to `~/.zshrc` next to the `ASC_API_*` variables — it's a one-time setup, not a per-release step.
- **Sparkle release-dialog notes**: the appcast's `<description>` CDATA is auto-populated by `publish-update.sh` with a short stub that links to the GitHub release page (e.g., `https://github.com/bvalentino/clearway/releases/tag/v1.0.1`). Users clicking *Check for Updates…* see "See the v1.0.1 release notes on GitHub for details" with a clickable link. The actual changelog lives in the GitHub release body, which `gh release create --generate-notes` auto-populates from merged PRs since the previous tag — single source of truth, nothing hand-written per release.
- **GitHub Pages hosting**: the appcast and release notes are served from `docs/` on `main` via GitHub Pages. One-time enablement: in the GitHub UI, **Settings → Pages → Build and deployment → Deploy from a branch → `main` / `/docs`**.

### Testing an update locally

Before the first public release — and after any change that touches Sparkle
wiring, signing, or the appcast — verify the update cycle end-to-end against a
local `file://` appcast. This catches signing and plist-injection bugs without
publishing anything to GitHub or notifying real users. Run once per
Sparkle-affecting change.

1. **Build version N** (the "old" build Sparkle will upgrade away from):

   ```bash
   ./scripts/release.sh        # bumps e.g. CURRENT_PROJECT_VERSION to 2
   ./scripts/notarize.sh
   ./scripts/package-dmg.sh
   cp release/Clearway-*.dmg /tmp/clearway-N.dmg
   ```

   Open `/tmp/clearway-N.dmg` and drag `Clearway.app` onto the Applications
   symlink inside the DMG window so it lands in `/Applications`. **Do not
   launch it yet** — launching would let it phone home to the real appcast and
   pollute the test.

2. **Build version N+1** (the "new" build Sparkle should pick up):

   ```bash
   ./scripts/release.sh        # bumps CURRENT_PROJECT_VERSION to 3
   ./scripts/notarize.sh
   ./scripts/package-dmg.sh
   cp release/Clearway-*.dmg /tmp/clearway-N-plus-1.dmg
   ```

3. **Produce a local appcast that points at the N+1 DMG**. Hand-craft a minimal
   feed at `/tmp/clearway-appcast.xml` with a single `<item>` whose
   `<enclosure url="file:///tmp/clearway-N-plus-1.dmg" ...>` references the
   DMG on disk. The easiest way to get a correctly signed `<item>` is to run
   `scripts/publish-update.sh` against `/tmp/clearway-N-plus-1.dmg` once to
   produce a valid `sparkle:edSignature` attribute, then lift that `<item>`
   out of the generated `docs/appcast.xml`, paste it into
   `/tmp/clearway-appcast.xml`, and `git checkout docs/appcast.xml` to undo
   the publish-script side effect. Rewrite the enclosure URL to
   `file:///tmp/clearway-N-plus-1.dmg`.

   The `sparkle:edSignature` value MUST match the **exact bytes** of
   `/tmp/clearway-N-plus-1.dmg` — do not modify, re-sign, or re-notarize the
   DMG after signing the appcast entry. Confirm the feed parses:

   ```bash
   xmllint --noout /tmp/clearway-appcast.xml
   ```

4. **Redirect the installed N build at the local appcast** using the
   `SUFeedURL` defaults override, which Sparkle reads at runtime and which
   wins over the `SUFeedURL` baked into `Info.plist`:

   ```bash
   defaults write app.getclearway.mac SUFeedURL file:///tmp/clearway-appcast.xml
   ```

   No rebuild required — this only affects the installed binary for the
   duration of the test.

5. **Trigger the update from inside the installed app**: launch
   `/Applications/Clearway.app`, open the **Clearway** menu, and click
   **Check for Updates…**. Sparkle should report a new version available,
   verify the ed25519 signature against the `SUPublicEDKey` baked into the
   current (N) build, download the DMG from the `file://` URL, and prompt
   to install. Accept the prompts and let it relaunch.

6. **Confirm the installed build is now N+1**:

   ```bash
   plutil -p /Applications/Clearway.app/Contents/Info.plist | grep CFBundleVersion
   ```

   The printed `CFBundleVersion` must match the N+1 build number bumped in
   step 2. If it still reads N, Sparkle failed silently — inspect
   `~/Library/Logs/DiagnosticReports/` and the system log for Sparkle output
   before shipping.

7. **Clean up**:

   ```bash
   defaults delete app.getclearway.mac SUFeedURL
   rm /tmp/clearway-N.dmg /tmp/clearway-N-plus-1.dmg /tmp/clearway-appcast.xml
   ```

   Verify the defaults override is gone:

   ```bash
   defaults read app.getclearway.mac SUFeedURL
   ```

   should print `The domain/default pair of (app.getclearway.mac, SUFeedURL)
   does not exist`. After the delete, the next launch of the installed
   Clearway.app falls back to the `SUFeedURL` baked into `Info.plist` (the
   real GitHub Pages URL), as intended.

If any step fails — missing menu item, signature rejection, wrong post-update
`CFBundleVersion`, XML parse error — do **not** proceed with the first public
release. Fix the underlying bug, rebuild, and re-run the dry-run from step 1.

## Release flow

Prerequisites every release:

1. Start from `main` with a clean tree: `git checkout main && git pull --ff-only`.
2. Confirm `ASC_API_KEY_PATH`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, and `SPARKLE_PRIVATE_KEY_PATH` are exported (ideally permanently in `~/.zshrc`). No per-release release-notes file is needed — the appcast's Sparkle update-dialog description is auto-generated as a link to the GitHub release page, and the GitHub release body is auto-generated from merged PRs by `gh release create --generate-notes`.

Then the pipeline itself:

```bash
./scripts/release.sh        # prompts for new MARKETING_VERSION (empty = keep current),
                            # bumps CURRENT_PROJECT_VERSION, regenerates xcodeproj,
                            # builds signed Release, zips
./scripts/notarize.sh       # submits zip, waits, staples ticket, verifies with spctl
./scripts/package-dmg.sh    # wraps stapled .app in signed + notarized + stapled DMG
./scripts/publish-update.sh # signs DMG, writes docs/appcast.xml, copies DMG to
                            # release/Clearway.dmg, prints gh release cmd
```

`release.sh` shows the current `MARKETING_VERSION` and prompts for the new one at the top of its run — enter e.g. `1.0.1` to bump, or press Enter to keep the current value. Both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are then written to `project.yml` and `xcodegen generate` propagates them into `Clearway.xcodeproj/project.pbxproj` before `xcodebuild` runs.

Total wall-clock time is about 10 minutes — dominated by two notary round-trips (one for the `.app` inside the zip, one for the DMG wrapper).

`publish-update.sh` prints a ready-to-paste `gh release create` command. Run it **before** you commit and push the appcast, so the DMG is reachable by the time GitHub Pages redeploys the feed:

```bash
# Uploads BOTH the versioned DMG (for Sparkle to fetch) and release/Clearway.dmg
# (for the landing page's fixed-filename /releases/latest/download/Clearway.dmg
# URL). Same bytes → same Sparkle signature → both paths verify identically.
# --generate-notes tells GitHub to auto-build the release body from merged PRs
# since the previous tag — equivalent to clicking "Generate release notes" in
# the web UI, and serves as the canonical changelog that Sparkle's update
# dialog links back to via the appcast <description> stub.
gh release create v1.0.1 \
  release/Clearway-1.0.1-<sha>.dmg \
  release/Clearway.dmg \
  --repo bvalentino/clearway \
  --title v1.0.1 \
  --generate-notes

# Then commit the three files the pipeline touched and push. The push
# triggers GitHub Pages to redeploy docs/appcast.xml, which makes the new
# version visible to installed Sparkle clients within 30–60 seconds.
git add project.yml Clearway.xcodeproj/project.pbxproj docs/appcast.xml
git commit -m "Release v1.0.1"
git push
```

Outputs in `release/` after the pipeline runs:

- `Clearway-<version>-<sha>.zip` — signed but **not** notarized. Intermediate artifact.
- `Clearway-<version>-<sha>-notarized.zip` — signed and stapled. Valid to distribute if you prefer a zip.
- `Clearway-<version>-<sha>.dmg` — signed, notarized, and stapled DMG with a drag-to-Applications layout. Referenced by the Sparkle appcast; the historical breadcrumb on the GitHub release page.
- `Clearway.dmg` — byte-for-byte copy of the versioned DMG, created by `publish-update.sh`. Uploaded as a second asset of the same release so the landing page's `https://github.com/bvalentino/clearway/releases/latest/download/Clearway.dmg` URL keeps resolving without any landing-page changes per release.

Both the DMG and the `.app` inside it are stapled, so extracting the app and deleting the DMG still works offline.

> **First-release bootstrap**: users running the current pre-Sparkle `1.0.0` build will never receive an automatic update to any later version, because that build does not contain the Sparkle updater. They must reinstall once by hand from the GitHub release page. From the next release onward, every subsequent version auto-updates normally. There is no way around this — it is the unavoidable cost of not having Sparkle wired into the version they currently run.

> **Rollback**: to roll back a bad update, edit `docs/appcast.xml` to remove or re-point the latest `<item>` element and `git push`. New installs and not-yet-updated users will then see the previous good version. Users who already downloaded and installed the bad build cannot be un-updated; they have to wait for the next good release. Plan rollouts accordingly.

> **First-launch consent**: Sparkle shows a one-time consent prompt the first time it would contact the update server, asking the user whether to enable automatic checks. This is expected behavior, not a bug. Users who decline lose automatic checks but can still trigger *Clearway → Check for Updates…* manually from the menu.

## Verifying a build manually

```bash
# DMG
spctl -a -t open --context context:primary-signature -vv release/Clearway-*.dmg
xcrun stapler validate release/Clearway-*.dmg

# Or the .app inside the notarized zip
unzip -o release/Clearway-*-notarized.zip -d /tmp/clearway-check
codesign -dvv /tmp/clearway-check/Clearway.app
spctl -a -vv /tmp/clearway-check/Clearway.app
xcrun stapler validate /tmp/clearway-check/Clearway.app
```

`spctl` should report `accepted, source=Notarized Developer ID` for both.

## Troubleshooting

If `./scripts/notarize.sh` reports `status=Invalid`, it will automatically fetch and print the detailed log from `notarytool`. The most common causes:

- **"The signature does not include a secure timestamp"** — `OTHER_CODE_SIGN_FLAGS = --timestamp` is missing from the Release config in `project.yml`.
- **"The executable requests the com.apple.security.get-task-allow entitlement"** — `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` is missing from the Release config. Xcode injects `get-task-allow=true` by default during `xcodebuild build`; disabling injection forces it to use only `Clearway.entitlements`.
- **New hardened runtime exception needed** — if `libghostty` starts requiring JIT, dyld env vars, etc., notarytool will name the exact entitlement key. Add it to `Clearway.entitlements` and rebuild.

Debug builds (`./scripts/build.sh`, `./scripts/run.sh`) still use ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) with hardened runtime off — the Release signing settings are scoped to the Release configuration only, so the local dev loop is unaffected.
