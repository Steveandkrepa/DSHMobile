#!/usr/bin/env bash
# TEMPORARY (branch diag/placard-airlift-probe only).
# Not a DSHMobile build: clones the placard fork, builds the Airlift
# xcframework from the AirCard fork, swaps it into placard's Vendor, and
# packages an unsigned IPA. Invoked with (scheme) (configuration) (out.ipa),
# all three ignored except the output path.
set -euo pipefail

OUTPUT="${3:-$PWD/build/placard-unsigned.ipa}"

PLACARD_REPO="${PLACARD_REPO:-https://github.com/Steveandkrepa/placard.git}"
PLACARD_REF="${PLACARD_REF:-diag/airlift-read-probe}"
AIRCARD_REPO="${AIRCARD_REPO:-https://github.com/Steveandkrepa/AirCard-iOS.git}"
AIRCARD_REF="${AIRCARD_REF:-diag/container-read-probe}"

WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/placard.XXXXXX")"
echo "==> work dir: $WORK"

echo "==> clone AirCard ($AIRCARD_REF)"
git clone --quiet --depth 1 --branch "$AIRCARD_REF" "$AIRCARD_REPO" "$WORK/aircard"

echo "==> build AirliftFFI.xcframework"
export DEVELOPER_DIR="$(xcode-select -p)"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"
( cd "$WORK/aircard" && bash build-ios.sh )

echo "==> clone placard ($PLACARD_REF)"
git clone --quiet --depth 1 --branch "$PLACARD_REF" "$PLACARD_REPO" "$WORK/placard"

VENDOR="$WORK/placard/Vendor/AirCard"
echo "==> swap in the freshly built framework"
rm -rf "$VENDOR/AirliftFFI.xcframework"
cp -R "$WORK/aircard/AirliftFFI.xcframework" "$VENDOR/AirliftFFI.xcframework"

echo "==> regenerate SHA256SUMS for the framework"
cd "$WORK/placard"
tmp="$(mktemp)"
grep -v 'AirliftFFI.xcframework' Vendor/AirCard/SHA256SUMS > "$tmp" || true
find Vendor/AirCard/AirliftFFI.xcframework -type f | sort | while read -r f; do
  shasum -a 256 "$f"
done >> "$tmp"
sort -k2 "$tmp" -o Vendor/AirCard/SHA256SUMS
rm -f "$tmp"
cat Vendor/AirCard/SHA256SUMS

echo "==> verify Airlift vendor"
bash scripts/verify-airlift.sh

VERSION="$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' placard.xcodeproj/project.pbxproj | head -1)"
echo "==> placard version: $VERSION"

mkdir -p "$(dirname "$OUTPUT")"
ARCHIVE="$WORK/build/placard.xcarchive"
xcodebuild archive \
  -project placard.xcodeproj \
  -scheme placard \
  -configuration "${2:-Release}" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO

APP="$ARCHIVE/Products/Applications/placard.app"
echo "==> verify archive"
bash scripts/verify-airlift.sh "$APP" "$VERSION"

PKG="$WORK/build/Payload"
mkdir -p "$PKG"
cp -R "$APP" "$PKG/"
( cd "$WORK/build" && zip -qry "$OUTPUT" Payload )
echo "==> wrote $OUTPUT ($(stat -f%z "$OUTPUT") bytes)"
