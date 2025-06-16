#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname -- "${SCRIPT_DIR}")" && pwd)"
SOURCE_FOLDER="${PROJECT_ROOT}/Dist/Release"
FINAL_DIR="${PROJECT_ROOT}/Dist/Final"
APP_NAME="MountMate"

if [[ -f "$PROJECT_ROOT/.env.local" ]]; then
  source "$PROJECT_ROOT/.env.local"
else
  echo "❌ .env.local not found in root directory."
  exit 1
fi
: "${CERTIFICATE_NAME:?CERTIFICATE_NAME is required}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is required}"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"

APP_PATH="${SOURCE_FOLDER}/${APP_NAME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "❌ ${APP_PATH} not found. Build your app first."
  exit 1
fi

VERSION=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString)
if [[ -z "${VERSION}" ]]; then
  echo "❌ Could not read version from Info.plist"
  exit 1
fi
ZIP_NAME="${APP_NAME}_${VERSION}.zip"
DMG_NAME="${APP_NAME}_${VERSION}.dmg"

# Build Release

APPCAST_NAME="appcast.xml"
UPDATE_URL="https://homielab.github.io/mountmate"
DOCS_DIR="$PROJECT_ROOT/docs"
ASSETS_DIR="$PROJECT_ROOT/assets"

echo "📦 Building ${APP_NAME} v${VERSION}"
echo "🧹 Cleaning up old files..."
rm -rf "${FINAL_DIR}"
mkdir -p "${FINAL_DIR}"

cd "${SOURCE_FOLDER}"

echo "📦 Creating Sparkle-compatible zip..."
zip -r --symlinks "${ZIP_NAME}" "${APP_NAME}.app"
mv "${ZIP_NAME}" "${FINAL_DIR}/"

echo "🛰️ Generating Sparkle appcast..."
generate_appcast "${FINAL_DIR}" \
  --download-url-prefix "${UPDATE_URL}" \
  --ed-key-file "${SPARKLE_PRIVATE_KEY}" \
  -o "${APPCAST_NAME}"
mv "${APPCAST_NAME}" "${DOCS_DIR}/${APPCAST_NAME}"

echo "📀 Creating DMG..."
create-dmg \
  --volicon "${ASSETS_DIR}/icon.icns" \
  --volname "${APP_NAME} v${VERSION}" \
  --background "${ASSETS_DIR}/icon.png" \
  --window-pos 200 120 \
  --window-size 640 480 \
  --icon-size 128 \
  --icon "${APP_NAME}.app" 160 240 \
  --hide-extension "${APP_NAME}.app" \
  --app-drop-link 480 240 \
  "${DMG_NAME}" "${SOURCE_FOLDER}"

echo "🔏 Signing and notarizing DMG..."
codesign --force --sign "${CERTIFICATE_NAME}" "${DMG_NAME}"
xcrun notarytool submit "${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG_NAME}"
mv "${DMG_NAME}" "${FINAL_DIR}/"

echo ""
echo "✅ Build complete! Files are in the '${FINAL_DIR}' directory:"
echo "  - ${ZIP_NAME} (for Sparkle updates)"
echo "  - ${DMG_NAME} (for manual download)"
echo "  - ${APPCAST_NAME} (Sparkle feed)"
echo ""

