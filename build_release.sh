#!/usr/bin/env bash
# Builds a Developer ID signed, notarized DMG of Meeting Notes.
# Whisper and speaker models are not bundled. The app downloads them on first use.
#
# From a fork, override signing:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID NOTARY_PROFILE=my-profile ./build_release.sh
# Store notary credentials once with:
#   xcrun notarytool store-credentials my-profile --apple-id YOU --team-id TEAMID --password APP_SPECIFIC_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Meeting Notes"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Soon Up GmbH (6A2SZH3VT5)}"
TEAM_ID="${TEAM_ID:-6A2SZH3VT5}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ainstype-notary}"
VERSION=$(grep CFBundleShortVersionString project.yml | sed -E 's/.*"(.*)".*/\1/')
DMG="dist/MeetingNotes-${VERSION}.dmg"
DERIVED="build/release"
APP="${DERIVED}/Build/Products/Release/${APP_NAME}.app"

echo "=== Building ${APP_NAME} ${VERSION} ==="
xcodegen generate
rm -rf "${DERIVED}" dist
mkdir -p build
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Release \
  -derivedDataPath "${DERIVED}" -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > build/release.log 2>&1 || { tail -40 build/release.log; echo "Build failed, see build/release.log"; exit 1; }

echo "=== Verifying signature ==="
codesign --verify --deep --strict --verbose=2 "${APP}"
codesign -dv "${APP}" 2>&1 | grep -E "Authority=Developer ID|flags"

echo "=== Creating DMG ==="
mkdir -p dist
STAGE=$(mktemp -d)
cp -R "${APP}" "${STAGE}/"
create-dmg --volname "${APP_NAME}" --window-pos 200 120 --window-size 600 400 \
  --icon-size 110 --icon "${APP_NAME}.app" 150 185 --app-drop-link 450 185 \
  --hide-extension "${APP_NAME}.app" "${DMG}" "${STAGE}"
rm -rf "${STAGE}"
codesign --sign "${IDENTITY}" --timestamp "${DMG}"

echo "=== Notarizing ==="
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"
spctl -a -t open --context context:primary-signature -v "${DMG}"

echo "=== Done: ${DMG} ==="
