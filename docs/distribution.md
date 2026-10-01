# Distributing BumpyRide Clip

The source repository can stay private. Share only the final DMG and its SHA-256
checksum. The DMG contains the native app, an Applications shortcut, and a short
installation guide. It includes no sample videos, web server, or source files.
The app currently requires macOS 26.2 or later and builds for Apple silicon and Intel.

## Local packaging check

```sh
scripts/build-dmg.sh --local
```

This creates an explicitly named `LOCAL-UNNOTARIZED.dmg` under a new directory in
`output/releases/`. It is an ad-hoc signed packaging test, **not a public release**.
It does not use Apple credentials or upload anything. Inspect the mounted image
and its contents; Gatekeeper approval is not expected for this local build.

Every build uses its own temporary build directory, runs the native tests, and
verifies the app's architectures, signature, sandbox, and resource contents.
Temporary build files are removed on exit; the DMG, checksum, and logs remain.
Running `output/native` development apps are never overwritten. Quit an installed
copy before replacing it with a newer build to avoid file-bookmark signature errors.

## One-time distribution setup

1. In Xcode Settings → Apple Accounts → your team → Manage Certificates, create
   or import a **Developer ID Application** certificate and its private key.
   An Apple Development or Apple Distribution certificate is not interchangeable.
   Creating Developer ID certificates requires the team's Account Holder role.
   No Developer ID Installer certificate is needed for this drag-to-Applications DMG.
2. List available identities with `security find-identity -v -p codesigning`.
3. Store notarization credentials interactively in your login Keychain:

   ```sh
   xcrun notarytool store-credentials bumpyride-clip
   ```

   Follow the local prompts using an App Store Connect API key, or your Apple ID,
   team ID, and an app-specific password. Do not put passwords, private keys, or
   certificate exports in this repository or in chat. The build script uses only
   the Keychain profile name.

## Build a distributable DMG

```sh
RELEASE_VERSION=1.0 BUILD_NUMBER=1 scripts/build-dmg.sh \
  --identity 'Developer ID Application: Your Name (YOURTEAMID)' \
  --notary-profile bumpyride-clip
```

Omit the version variables to use the Xcode project versions. Increment the build
number for subsequent releases. `DEVELOPER_DIR` defaults to
`/Applications/Xcode.app/Contents/Developer` and can be overridden.

The script signs with hardened runtime and sandbox/file-access entitlements,
without debugging access. It submits the app to Apple's notary service, staples
the accepted ticket to the app, packages and signs the DMG, then notarizes and
staples the DMG as well. It checks Gatekeeper acceptance and writes `SHA256SUMS.txt`
after stapling. No download is published automatically.

If notarization fails or is interrupted, consult `notary-app.json` or
the `notary-dmg.*` receipt in that run's output directory. Use the submission ID to retrieve
the result or detailed log:

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile bumpyride-clip
xcrun notarytool log SUBMISSION_ID --keychain-profile bumpyride-clip output/notary-log.json
```

Do not distribute an image from a failed run. Correct the issue and rerun the
script. A signed DMG that was already built can be finished without rebuilding:

```sh
scripts/notarize-dmg.sh '/path/to/signed.dmg' bumpyride-clip
```

This submits the image, staples the ticket, checks Gatekeeper acceptance, and
writes an adjacent `.dmg.sha256` file. If its filename ends with
`-PENDING-NOTARIZATION.dmg`, that suffix is removed only after every check passes.
An app notarized through Xcode's existing Apple account can be packaged this way,
but the signed DMG still needs its own notarization via the Keychain profile.

Keep the receipt and build logs for diagnosis; share only the successful
DMG and checksum. Test a downloaded release on a separate Mac before publishing
widely, including video linking, reopening a saved project, and clip export.

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
[notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow),
and [packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).
