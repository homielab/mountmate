#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="${PROJECT_ROOT}/MountMate.xcodeproj/project.pbxproj"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: scripts/create-draft-release.sh [--dry-run]

Creates an annotated tag for the current MARKETING_VERSION, pushes it to
origin, and creates a GitHub draft release with notes generated from commits
since the previous version tag.

Environment:
  GITHUB_REPOSITORY  Override the GitHub repository (for example, owner/repo).
EOF
}

case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

cd "${PROJECT_ROOT}"

if [[ ! -f "${PROJECT_FILE}" ]]; then
  echo "Error: Xcode project file not found." >&2
  exit 1
fi

VERSION="$({
  awk -F '= ' '/MARKETING_VERSION =/ { gsub(/[;[:space:]]/, "", $2); print $2; exit }' \
    "${PROJECT_FILE}"
})"

if [[ -z "${VERSION}" ]]; then
  echo "Error: Could not read MARKETING_VERSION from the Xcode project." >&2
  exit 1
fi

TAG="v${VERSION}"
PREVIOUS_TAG="$(git tag --list 'v*' --sort=-version:refname | grep -Fxv "${TAG}" | head -n 1 || true)"

if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
  REPOSITORY="${GITHUB_REPOSITORY}"
else
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  REPOSITORY="$(printf '%s' "${ORIGIN_URL}" \
    | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
fi

if [[ -z "${REPOSITORY}" || "${REPOSITORY}" == "${ORIGIN_URL:-}" ]]; then
  echo "Error: Could not determine the GitHub repository from origin." >&2
  echo "Set GITHUB_REPOSITORY=owner/repo and try again." >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  TAG_COMMIT="$(git rev-list -n 1 "${TAG}")"
  HEAD_COMMIT="$(git rev-parse HEAD)"
  if [[ "${TAG_COMMIT}" != "${HEAD_COMMIT}" ]]; then
    echo "Error: ${TAG} already points to a different commit (${TAG_COMMIT})." >&2
    exit 1
  fi
  TAG_EXISTS=true
else
  TAG_EXISTS=false
fi

NOTES_FILE="$(mktemp "${TMPDIR:-/tmp}/mountmate-release-notes.XXXXXX")"
FEATURES_FILE="$(mktemp "${TMPDIR:-/tmp}/mountmate-release-features.XXXXXX")"
FIXES_FILE="$(mktemp "${TMPDIR:-/tmp}/mountmate-release-fixes.XXXXXX")"
OTHER_FILE="$(mktemp "${TMPDIR:-/tmp}/mountmate-release-other.XXXXXX")"
trap 'rm -f "${NOTES_FILE}" "${FEATURES_FILE}" "${FIXES_FILE}" "${OTHER_FILE}"' EXIT

COMMIT_RANGE="HEAD"
if [[ -n "${PREVIOUS_TAG}" ]]; then
  COMMIT_RANGE="${PREVIOUS_TAG}..HEAD"
fi

while IFS='|' read -r HASH SUBJECT; do
  [[ -n "${HASH}" ]] || continue

  # Release bumps and generated distribution metadata are not useful release notes.
  if [[ "${SUBJECT}" =~ ^release[[:space:]] ]] \
    || [[ "${SUBJECT}" =~ ^chore:[[:space:]]update[[:space:]]appcast ]]; then
    continue
  fi

  CLEAN_SUBJECT="$(printf '%s' "${SUBJECT}" \
    | sed -E 's/^(feat|fix|refactor|perf|style|docs|chore)(\([^)]*\))?!?:[[:space:]]*//')"
  ENTRY="- ${CLEAN_SUBJECT} ([${HASH}](https://github.com/${REPOSITORY}/commit/${HASH}))"

  case "${SUBJECT}" in
    feat:*|feat\(* ) printf '%s\n' "${ENTRY}" >> "${FEATURES_FILE}" ;;
    fix:*|fix\(* ) printf '%s\n' "${ENTRY}" >> "${FIXES_FILE}" ;;
    *) printf '%s\n' "${ENTRY}" >> "${OTHER_FILE}" ;;
  esac
done < <(git log "${COMMIT_RANGE}" --no-merges --format='%h|%s')

{
  echo "## What's Changed"
  echo
  if [[ -s "${FEATURES_FILE}" ]]; then
    echo "### Added"
    echo
    cat "${FEATURES_FILE}"
    echo
  fi
  if [[ -s "${FIXES_FILE}" ]]; then
    echo "### Fixed"
    echo
    cat "${FIXES_FILE}"
    echo
  fi
  if [[ -s "${OTHER_FILE}" ]]; then
    echo "### Other Changes"
    echo
    cat "${OTHER_FILE}"
    echo
  fi
  if [[ -n "${PREVIOUS_TAG}" ]]; then
    echo "**Full Changelog**: https://github.com/${REPOSITORY}/compare/${PREVIOUS_TAG}...${TAG}"
  fi
} > "${NOTES_FILE}"

echo "Version:       ${VERSION}"
echo "Tag:           ${TAG}"
echo "Previous tag:  ${PREVIOUS_TAG:-none}"
echo "Repository:    ${REPOSITORY}"
echo
cat "${NOTES_FILE}"

if [[ "${DRY_RUN}" == true ]]; then
  echo
  echo "Dry run complete; no tag or GitHub release was created."
  exit 0
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: The working tree has uncommitted changes." >&2
  echo "Commit or stash them before creating a release tag." >&2
  exit 1
fi

command -v gh >/dev/null 2>&1 || {
  echo "Error: GitHub CLI (gh) is required." >&2
  exit 1
}
gh auth status >/dev/null

if gh release view "${TAG}" --repo "${REPOSITORY}" >/dev/null 2>&1; then
  echo "Error: GitHub release ${TAG} already exists." >&2
  exit 1
fi

if [[ "${TAG_EXISTS}" == false ]]; then
  git tag -a "${TAG}" -m "Release ${TAG}"
fi

git push origin "${TAG}"

gh release create "${TAG}" \
  --repo "${REPOSITORY}" \
  --title "MountMate ${VERSION}" \
  --notes-file "${NOTES_FILE}" \
  --verify-tag \
  --draft

echo "Draft release created: https://github.com/${REPOSITORY}/releases/tag/${TAG}"
