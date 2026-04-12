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

Start from a clean `main`:

```bash
git checkout main && git pull --ff-only
```

Then run the pipeline (wall-clock ~10 minutes, dominated by two notary round-trips):

```bash
./scripts/release.sh        # prompts for new MARKETING_VERSION, bumps CURRENT_PROJECT_VERSION,
                            # regenerates xcodeproj, builds signed Release, zips
./scripts/notarize.sh       # submits zip, waits, staples ticket, verifies with spctl
./scripts/package-dmg.sh    # wraps stapled .app in a signed + notarized + stapled DMG
./scripts/publish-update.sh # signs DMG, writes docs/appcast.xml, prints gh release cmd
```

`publish-update.sh` prints a ready-to-paste `gh release create` command. Run it **before** committing and pushing, so the DMG is reachable when GitHub Pages redeploys the appcast feed:

```bash
gh release create v<VERSION> \
  release/Clearway-<VERSION>-<sha>.dmg \
  release/Clearway.dmg \
  --repo bvalentino/clearway \
  --title v<VERSION> \
  --generate-notes

git add project.yml Clearway.xcodeproj/project.pbxproj docs/appcast.xml
git commit -m "Release v<VERSION>"
git push
```

Both DMGs are uploaded as release assets: the versioned one is fetched by Sparkle via `docs/appcast.xml`, and `Clearway.dmg` keeps the landing page's `/releases/latest/download/Clearway.dmg` URL resolving. Same bytes, same signature.

> **Rollback**: remove or re-point the latest `<item>` in `docs/appcast.xml` and push. New installs and not-yet-updated users get the previous good version. Users who already installed the bad build have to wait for the next release.

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

Both should report `accepted, source=Notarized Developer ID`.

## Troubleshooting

If `notarize.sh` reports `status=Invalid`, it auto-fetches and prints the `notarytool` log. Common causes:

- **"The signature does not include a secure timestamp"** — `OTHER_CODE_SIGN_FLAGS = --timestamp` missing from the Release config in `project.yml`.
- **"The executable requests the com.apple.security.get-task-allow entitlement"** — `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` missing from the Release config. Xcode injects `get-task-allow=true` by default; disabling injection forces it to use only `Clearway.entitlements`.
- **New hardened runtime exception needed** — `notarytool` names the exact entitlement key; add it to `Clearway.entitlements` and rebuild.

Debug builds (`./scripts/build.sh`, `./scripts/run.sh`) use ad-hoc signing with hardened runtime off, so the dev loop is unaffected.
