#!/usr/bin/env bash
# Run on a Mac with an iOS 17.6+ SDK. The resulting IPA still requires Apple signing.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'BUILD BLOCKED: macOS and full Xcode 26+ are required; Linux cannot build an iPhone app.' >&2
  exit 2
fi
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
if [[ "${SDK_VERSION%%.*}" -lt 17 ]]; then
  echo "BUILD BLOCKED: iOS 17.6+ SDK required; selected SDK is $SDK_VERSION." >&2
  exit 2
fi
mkdir -p build
# The imported project is valid OpenStep syntax, but recent Xcode versions can
# reject its compact legacy formatting.  `pbxproj` is already part of the CI
# verification requirements; rewriting through it preserves every object while
# producing the canonical Xcode project representation before the real build.
python3 - <<'PY'
from pbxproj import XcodeProject

path = "OutdoorPhotoAssistant.xcodeproj/project.pbxproj"
project = XcodeProject.load(path)
project.save(path)
PY
for CONFIG in Debug Release; do
  xcodebuild \
    -project OutdoorPhotoAssistant.xcodeproj \
    -scheme OutdoorPhotoAssistant \
    -configuration "$CONFIG" \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "build/$CONFIG" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
    build 2>&1 | tee "build/build-$CONFIG.log"
done
APP='build/Release/Build/Products/Release-iphoneos/OutdoorPhotoAssistant.app'
test -d "$APP"
STAGING=$(mktemp -d "$PWD/build/ipa.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
OUTPUT="$PWD/build/OutdoorPhotoAssistant-unsigned.ipa"
rm -f "$OUTPUT"
(cd "$STAGING" && /usr/bin/zip -qry "$OUTPUT" Payload)
echo "BUILT (UNSIGNED): $OUTPUT"
