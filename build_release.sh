#!/usr/bin/env bash
# Builds a Developer ID signed, notarized DMG of Meeting Notes.
# Whisper and speaker models are not bundled. The app downloads them on first use.
#
# From a fork, override signing:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID NOTARY_PROFILE=my-profile ./build_release.sh
# Store notary credentials once with:
#   xcrun notarytool store-credentials my-profile --apple-id YOU --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#
# With SUPublicEDKey set in project.yml, the script also writes dist/appcast.xml, the Sparkle update feed.
# Upload it to the GitHub release together with the DMG. See README, section Updates.
# The repository comes from SUFeedURL in project.yml. Set SPARKLE_KEY_FILE when the private update key
# is in a file and not in the login Keychain.
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
SPARKLE_BIN="${DERIVED}/SourcePackages/artifacts/sparkle/Sparkle/bin"

echo "=== Building ${APP_NAME} ${VERSION} ==="
xcodegen generate
rm -rf "${DERIVED}" dist
mkdir -p build
xcodebuild -project MeetingNotes.xcodeproj -scheme MeetingNotes -configuration Release \
  -derivedDataPath "${DERIVED}" -destination 'generic/platform=macOS' \
  DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="${IDENTITY}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > build/release.log 2>&1 || { tail -40 build/release.log; echo "Build failed, see build/release.log"; exit 1; }

echo "=== Signing Sparkle helpers ==="
# Xcode signs only the framework, not the helpers inside it. Notarization needs all of them signed.
SPARKLE="${APP}/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --sign "${IDENTITY}" --options runtime --timestamp "$@"; }
sign "${SPARKLE}/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "${SPARKLE}/Versions/B/XPCServices/Downloader.xpc"
sign "${SPARKLE}/Versions/B/Autoupdate"
sign "${SPARKLE}/Versions/B/Updater.app"
sign "${SPARKLE}"
sign --preserve-metadata=entitlements "${APP}"

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

echo "=== Creating update feed ==="
# After stapling, because the feed holds a signature of the final DMG.
INFO_PLIST="${APP}/Contents/Info.plist"
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "${INFO_PLIST}" 2>/dev/null || true)
if [[ -z "${PUBLIC_KEY// /}" ]]; then
  echo "No SUPublicEDKey in project.yml. Skipping the update feed. See README, section Updates."
  echo "=== Done: ${DMG} ==="
  exit 0
fi
FEED_URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "${INFO_PLIST}")
REPO_URL="${FEED_URL%/releases/latest/download/*}"
if [[ "${REPO_URL}" == "${FEED_URL}" ]]; then
  echo "SUFeedURL must be <repository URL>/releases/latest/download/appcast.xml, found: ${FEED_URL}"
  exit 1
fi
KEY_ARGS=()
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then KEY_ARGS=(--ed-key-file "${SPARKLE_KEY_FILE}"); fi
"${SPARKLE_BIN}/generate_appcast" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
  --download-url-prefix "${REPO_URL}/releases/download/v${VERSION}/" \
  --link "${REPO_URL}/releases" \
  --full-release-notes-url "${REPO_URL}/releases/tag/v${VERSION}" \
  -o dist/appcast.xml dist
# generate_appcast only warns when the private key does not match SUPublicEDKey, and installed apps reject such a feed.
if ! grep -q 'sparkle:edSignature=' dist/appcast.xml; then
  echo "dist/appcast.xml has no signature. The private update key does not match SUPublicEDKey."
  exit 1
fi

echo "=== Done: upload ${DMG} and dist/appcast.xml to the release v${VERSION} ==="
