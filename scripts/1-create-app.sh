#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$PROJECT_ROOT/MountMate.xcodeproj"
SCHEME="MountMate"
CONFIGURATION="Release"
BUILD_DIR="$PROJECT_ROOT/Dist/Build"
DIST_DIR="$PROJECT_ROOT/Dist/Release"
APP_NAME="MountMate"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
BUNDLE_ID="com.homielab.mountmate"

if [[ -f "$PROJECT_ROOT/.env.local" ]]; then
  source "$PROJECT_ROOT/.env.local"
else
  echo "❌ .env.local not found in root directory."
  exit 1
fi
: "${CERTIFICATE_NAME:?CERTIFICATE_NAME is required}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE is required}"

# === Build ===

echo "🧹 Cleaning previous builds..."
rm -rf "$BUILD_DIR" "$APP_PATH"

echo "🛠️ Building $APP_NAME..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  "ONLY_ACTIVE_ARCH=NO" \
  -destination "generic/platform=macOS" \
  clean build

BUILT_APP_PATH=$(find "$BUILD_DIR/Build/Products/$CONFIGURATION" -name "${APP_NAME}.app" -type d | head -n 1)
if [ -z "$BUILT_APP_PATH" ]; then
  echo "❌ Failed to find built .app."
  exit 1
fi

echo "🔏 Signing $APP_NAME with identity: $CERTIFICATE_NAME"
codesign --deep --force --verbose \
  --options runtime \
  --sign "$CERTIFICATE_NAME" \
  "$BUILT_APP_PATH"

echo "🚀 Submitting for notarization..."
ZIP_PATH="$DIST_DIR/${APP_NAME}.zip"
mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP_PATH" "$ZIP_PATH"

xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "📎 Stapling notarization ticket..."
xcrun stapler staple "$BUILT_APP_PATH"

echo "📦 Exporting notarized .app to $APP_PATH"
cp -R "$BUILT_APP_PATH" "$APP_PATH"

echo "Cleaning up..."
rm -rf "$BUILD_DIR"
rm -f "$ZIP_PATH"

echo "✅ Done. Notarized and exported to $APP_PATH"