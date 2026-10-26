#!/bin/bash

# Builds a release locally (app, zip, appcast, DMG, cask) without publishing
# anything. Releases are published by pushing a v* tag: the release workflow
# runs these steps and creates the GitHub release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "🚀 Starting local release build..."

echo "--------------------------------------------------------------------------------"
echo "Step 1: Create App"
echo "--------------------------------------------------------------------------------"
"$SCRIPT_DIR/1-create-app.sh"

echo "--------------------------------------------------------------------------------"
echo "Step 2: Build Release (DMG & Zip)"
echo "--------------------------------------------------------------------------------"
"$SCRIPT_DIR/2-build.sh"

echo "--------------------------------------------------------------------------------"
echo "Step 3: Generate Cask"
echo "--------------------------------------------------------------------------------"
"$SCRIPT_DIR/4-generate_cask.sh"

echo "--------------------------------------------------------------------------------"
echo "🎉 All steps completed. Nothing was published; push a v* tag to release."
