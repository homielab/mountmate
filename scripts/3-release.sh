#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_FOLDER="${PROJECT_ROOT}/Dist/Release"
FINAL_DIR="${PROJECT_ROOT}/Dist/Final"
APP_NAME="MountMate"

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

# === Create GitHub release ===

TAG="v${VERSION}"
GITHUB_REPO="homielab/mountmate"

echo "🚀 Publishing GitHub release ${TAG}..."
git tag | grep -q "${TAG}" || git tag "${TAG}"
git push origin "${TAG}"

if ! gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
  gh release create "${TAG}" \
    --repo "${GITHUB_REPO}" \
    --title "MountMate ${VERSION}" \
    --notes "Release for MountMate version ${VERSION}.

Download the DMG file and drag MountMate.app into your Applications folder.
Please report any bugs at https://github.com/homielab/mountmate/issues" \
    --target main
fi

gh release upload "${TAG}" \
  "${FINAL_DIR}/${ZIP_NAME}" \
  "${FINAL_DIR}/${DMG_NAME}" \
  --repo "${GITHUB_REPO}" --clobber

echo "✅ Done!"
echo "🔗 GitHub Release: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"