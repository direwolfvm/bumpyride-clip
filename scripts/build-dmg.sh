#!/bin/bash
# Build in isolation: never replace the .app used by a running development session.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build-dmg.sh --local
  scripts/build-dmg.sh --identity 'Developer ID Application: Name (TEAMID)' \
    --notary-profile bumpyride-clip

--local creates an ad-hoc signed, UNNOTARIZED testing image. Not for distribution.
The distribution mode requires a Developer ID Application identity and a Keychain
notarytool profile. It signs, notarizes, staples, and verifies the app and DMG.
Optional environment: DEVELOPER_DIR, RELEASE_VERSION (e.g. 1.0.1), BUILD_NUMBER (e.g. 2).
Outputs and logs go into a new directory under output/releases on every run.
EOF
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
mode=release
identity=
profile=
while (($#)); do
  case "$1" in
    --local) mode=local; shift ;;
    --identity) (($# >= 2)) || fail 'Missing signing identity'; identity=$2; shift 2 ;;
    --notary-profile) (($# >= 2)) || fail 'Missing Keychain profile'; profile=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown argument: $1" ;;
  esac
done
[[ $(uname -s) == Darwin ]] || fail 'This script requires macOS and Xcode.'
root=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
[[ -d "$DEVELOPER_DIR" ]] || fail 'Set DEVELOPER_DIR to your Xcode Developer directory.'
if [[ $mode == release ]]; then
  [[ $identity == 'Developer ID Application: '* ]] || fail 'Supply --identity with a Developer ID Application certificate name; Apple Development certificates cannot be used.'
  [[ -n $profile ]] || fail 'Supply --notary-profile with your notarytool Keychain profile name.'
  security find-identity -v -p codesigning | grep -F -- "\"$identity\"" >/dev/null || fail 'The signing certificate and its private key are not available in the Keychain.'
else
  [[ -z $identity && -z $profile ]] || fail '--local cannot be combined with distribution credentials.'
fi

# macOS ships Bash 3.2, where expanding an empty array under nounset fails.
settings=(ONLY_ACTIVE_ARCH=NO)
if [[ -n ${RELEASE_VERSION:-} ]]; then
  [[ $RELEASE_VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail 'RELEASE_VERSION must be numeric, such as 1.0.1.'
  settings+=("MARKETING_VERSION=$RELEASE_VERSION")
fi
if [[ -n ${BUILD_NUMBER:-} ]]; then
  [[ $BUILD_NUMBER =~ ^[1-9][0-9]*$ ]] || fail 'BUILD_NUMBER must be a positive integer.'
  settings+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

mkdir -p "$root/output/releases"
result=$(mktemp -d "$root/output/releases/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
work=$(mktemp -d "$result/.work.XXXXXX")
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'Build artifacts and logs: %s\n' "$result"

printf 'Running native tests…\n'
if ! xcrun swift test --package-path "$root/BumpyRide Clip" --scratch-path "$work/tests" >"$result/tests.log" 2>&1; then
  tail -n 60 "$result/tests.log" >&2; fail 'Native tests failed.'
fi
printf 'Building Release for Apple silicon and Intel…\n'
if ! xcodebuild -project "$root/BumpyRide Clip/BumpyRide Clip.xcodeproj" \
  -scheme 'BumpyRide Clip' -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$work/build" 'ARCHS=arm64 x86_64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  "${settings[@]}" build >"$result/build.log" 2>&1; then
  tail -n 60 "$result/build.log" >&2; fail 'Release build failed.'
fi

stage="$work/image"
mkdir -p "$stage"
app="$stage/BumpyRide Clip.app"
ditto "$work/build/Build/Products/Release/BumpyRide Clip.app" "$app"
# Explicit distribution entitlements: preserve the sandbox and file bookmarks,
# with no development-only get-task-allow entitlement.
entitlements="$work/distribution.plist"
cat >"$entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
</dict></plist>
EOF
if [[ $mode == release ]]; then
  codesign --force --sign "$identity" --options runtime --timestamp --entitlements "$entitlements" "$app"
else
  codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
fi
python3 "$root/scripts/verify-macos-app.py" "$app" "$mode" | tee "$result/app-verification.txt"

notarize() {
  local artifact=$1 label=$2
  printf 'Submitting %s to Apple for notarization…\n' "$label"
  xcrun notarytool submit "$artifact" --keychain-profile "$profile" --wait \
    --output-format json >"$result/notary-$label.json"
  python3 - "$result/notary-$label.json" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
if reply.get('status') != 'Accepted':
    raise SystemExit(f"Notarization not accepted: {reply}. See docs/distribution.md for retrieving the log.")
print(f"Notarization accepted: {reply['id']}")
PY
}
if [[ $mode == release ]]; then
  # Staple the app before packaging, so the installed app also carries its ticket.
  ditto -c -k --keepParent "$app" "$work/app.zip"
  notarize "$work/app.zip" app
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=2 "$app"
fi

ln -s /Applications "$stage/Applications"
cat >"$stage/Read Me.txt" <<'EOF'
BumpyRide Clip

Drag BumpyRide Clip into Applications, then open it from there.
Quit an older copy of the app before replacing it. Eject this disk after installing.

Requires macOS 26.2 or later. Supports Apple silicon and Intel Macs.

Open your BumpyRide ride JSON, then link the videos from that ride in recording
order. Use Video Sync and calibration to align reports with the footage.
Original videos stay in place. Projects contain metadata, not copies of videos.
No sample footage is included.
EOF
suffix=
if [[ $mode == local ]]; then
  suffix=-LOCAL-UNNOTARIZED
  printf '\nLOCAL TEST BUILD: Ad-hoc signed. Not notarized or ready for public distribution.\n' >>"$stage/Read Me.txt"
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist")
dmg="$result/BumpyRide-Clip-$version-$build$suffix.dmg"
hdiutil create -volname 'BumpyRide Clip' -srcfolder "$stage" -format UDZO -fs HFS+ "$dmg"
if [[ $mode == release ]]; then
  codesign --sign "$identity" --identifier com.herbertindustries.BumpyRide-Clip.dmg --timestamp "$dmg"
  "$root/scripts/notarize-dmg.sh" "$dmg" "$profile"
fi
hdiutil verify "$dmg"
(cd "$result" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS.txt)
printf '\nCreated: %s\n' "$dmg"
if [[ $mode == local ]]; then
  printf 'LOCAL TEST BUILD ONLY — Developer ID signing and notarization are still required.\n'
else
  printf 'Developer ID signed, notarized, stapled, and verified for distribution.\n'
fi
