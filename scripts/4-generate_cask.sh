#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FINAL_DIR="${PROJECT_ROOT}/Dist/Final"
DMG_FILE=$(find "$FINAL_DIR" -maxdepth 1 -name "MountMate_*.dmg" | head -n 1)

if [[ ! -f "$DMG_FILE" ]]; then
  echo "❌ DMG file not found in $FINAL_DIR"
  exit 1
fi

FILENAME=$(basename "$DMG_FILE")
VERSION=$(echo "$FILENAME" | sed -E 's/MountMate_([0-9.]+)\.dmg/\1/')

SHA256=$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')

echo "📦 Version detected: $VERSION"
echo "🔐 SHA256: $SHA256"

mkdir -p "Casks"
OUTPUT="Casks/mountmate.rb"
rm -f "$OUTPUT"

cat > "$OUTPUT" <<EOF
cask "mountmate" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/homielab/mountmate/releases/download/v#{version}/MountMate_#{version}.dmg"
  name "MountMate"
  desc "A menubar app to easily manage external drives"
  homepage "https://homielab.com/page/mountmate"

  auto_updates true
  app "MountMate.app"

  zap trash: [
    "~/Library/Preferences/com.homielab.mountmate.plist",
  ]
end
EOF

echo "✅ Cask file generated: $OUTPUT"