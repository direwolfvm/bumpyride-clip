#!/bin/bash
# Finish a signed image without rebuilding or resubmitting its notarized app.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 || $1 == --help ]]; then
  printf 'Usage: scripts/notarize-dmg.sh /path/to/signed.dmg [keychain-profile]\n'
  exit 1
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
dmg=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
profile=${2:-bumpyride-clip}
[[ -f "$dmg" && $dmg == *.dmg ]] || { printf 'A signed DMG is required.\n' >&2; exit 1; }
final=${dmg%-PENDING-NOTARIZATION.dmg}
if [[ $final != "$dmg" ]]; then
  final="$final.dmg"
  [[ ! -e "$final" ]] || { printf 'Final image already exists: %s\n' "$final" >&2; exit 1; }
fi
codesign --verify --strict --verbose=2 "$dmg"
signature=$(codesign --display --verbose=4 "$dmg" 2>&1)
[[ $signature == *'Authority=Developer ID Application:'* && $signature == *'Timestamp='* ]] || {
  printf 'A Developer ID Application signature and secure timestamp are required.\n' >&2; exit 1;
}
receipt=$(mktemp "$(dirname "$dmg")/notary-dmg.XXXXXX")
printf 'Submitting the signed DMG to Apple; receipt: %s\n' "$receipt"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json >"$receipt"
python3 - "$receipt" <<'PY'
import json, sys
reply = json.load(open(sys.argv[1]))
if reply.get('status') != 'Accepted':
    raise SystemExit(f"Notarization not accepted: {reply}")
print(f"Notarization accepted: {reply['id']}")
PY
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
hdiutil verify "$dmg"
# Remove the pending label only after Apple's ticket and Gatekeeper pass.
if [[ $final != "$dmg" ]]; then mv "$dmg" "$final"; fi
(cd "$(dirname "$final")" && shasum -a 256 "$(basename "$final")" > "$(basename "$final").sha256")
printf '\nReady for distribution: %s\n' "$final"
