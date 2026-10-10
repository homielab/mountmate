#!/usr/bin/env bash
# Sets the version (from the release tag) and the next build number on the app
# target in the Xcode project, and extracts that version's notes from
# CHANGELOGS.md.
#
# Usage: scripts/prepare-release.sh v5.20     (or 5.20)
#
# Build number = build number at the previous v* tag + 1.
# Writes RELEASE_NOTES.md and prints VERSION/BUILD/TAG/PREVIOUS_TAG lines
# (appended to $GITHUB_OUTPUT when running in GitHub Actions).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
PBXPROJ="MountMate.xcodeproj/project.pbxproj"
CHANGELOG="CHANGELOGS.md"
REPO="${GITHUB_REPOSITORY:-homielab/mountmate}"

read_setting() { # $1 = setting, $2 = file content source (path or git object)
  awk -F '= ' -v key="$1" '$0 ~ key" =" { gsub(/[;[:space:]"]/, "", $2); print $2; exit }'
}

# --- Version (from the tag) ---
INPUT="${1:?Usage: $0 v<version>}"
VERSION="${INPUT#v}"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "❌ Invalid version tag: $INPUT" >&2; exit 1; }
TAG="v${VERSION}"

# Previous release = highest v* tag below this one.
PREVIOUS_TAG="$(git tag --list 'v*' | grep -Fxv "$TAG" \
  | { cat; echo "$TAG"; } | sort -V | grep -B1 -Fx "$TAG" | grep -Fxv "$TAG" || true)"

# --- Build number ---
CURRENT_VERSION="$(read_setting MARKETING_VERSION < "$PBXPROJ")"
CURRENT_BUILD="$(read_setting CURRENT_PROJECT_VERSION < "$PBXPROJ")"
if [[ -n "$PREVIOUS_TAG" ]]; then
  BASE_BUILD="$(git show "${PREVIOUS_TAG}:${PBXPROJ}" | read_setting CURRENT_PROJECT_VERSION)"
else
  BASE_BUILD="$CURRENT_BUILD"
fi
BUILD="$((BASE_BUILD + 1))"

# --- Release notes from CHANGELOGS.md ---
# Use "## <version>"; if missing, use "## Unreleased" and rename it to the
# version (committed with the release).
if ! grep -qxF "## ${VERSION}" "$CHANGELOG" && grep -qxF "## Unreleased" "$CHANGELOG"; then
  perl -pi -e "s/^## Unreleased\$/## ${VERSION}/ && \$done++ if !\$done" "$CHANGELOG"
  echo "📝 Renamed \"## Unreleased\" to \"## ${VERSION}\" in ${CHANGELOG}"
fi
NOTES_BODY="$(awk -v ver="$VERSION" '
  $0 == "## " ver { found = 1; next }
  found && (/^## / || /^---/) { exit }
  found { print }
' "$CHANGELOG" | sed -e '/./,$!d')"   # drop leading blank lines
if [[ -z "${NOTES_BODY//[[:space:]]/}" ]]; then
  echo "❌ No \"## ${VERSION}\" or \"## Unreleased\" section in ${CHANGELOG}. Add the release notes first." >&2
  exit 1
fi
{
  printf '%s\n\n' "$NOTES_BODY"
  echo "---"
  echo
  echo "Download the DMG and drag MountMate.app into your Applications folder, or update from inside the app."
  echo "Please report bugs at https://github.com/${REPO}/issues"
  if [[ -n "$PREVIOUS_TAG" ]]; then
    echo
    echo "**Full Changelog**: https://github.com/${REPO}/compare/${PREVIOUS_TAG}...${TAG}"
  fi
} > RELEASE_NOTES.md

# --- Update the app target only (test targets keep their own 1.0 / 1) ---
perl -pi -e "s/MARKETING_VERSION = \Q${CURRENT_VERSION}\E;/MARKETING_VERSION = ${VERSION};/g; \
             s/CURRENT_PROJECT_VERSION = \Q${CURRENT_BUILD}\E;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "$PBXPROJ"

echo "📦 ${CURRENT_VERSION} (${CURRENT_BUILD}) -> ${VERSION} (${BUILD}), previous release ${PREVIOUS_TAG:-none}"
OUT="VERSION=${VERSION}
BUILD=${BUILD}
TAG=${TAG}
PREVIOUS_TAG=${PREVIOUS_TAG}"
echo "$OUT"
[[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$OUT" >> "$GITHUB_OUTPUT"
exit 0
