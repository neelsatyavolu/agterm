#!/bin/bash
# Publishes the version in ./VERSION as a GitHub release that Sparkle installs from.
# Usage: scripts/release.sh            (bump VERSION and commit first)
#
# Steps: Developer ID sign → notarize + staple → zip → EdDSA-sign for Sparkle → appcast.xml
# → GitHub release v<version> with agterm-<version>.zip, agterm.zip (stable name for the
# website) and appcast.xml (the feed every installed copy polls).
# Needs the maintainer's 1Password items; see ~/Documents/GitHub/APPLE_SIGNING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="neelsatyavolu/agterm"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
OUT="dist/release"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
SPARKLE_KEY_ITEM="${AGTERM_SPARKLE_KEY_REF:-}"

if [ -n "$(git status --porcelain)" ]; then
    echo "error: commit your changes first (the release is built from the working tree)" >&2
    exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: $TAG already exists; bump VERSION" >&2
    exit 1
fi

echo "Loading signing and notarization credentials from 1Password…"
# shellcheck disable=SC1091
[ -f scripts/maintainer.local ] && source scripts/maintainer.local
# shellcheck disable=SC1091
source scripts/load-apple-creds.sh
SECRETS="$(mktemp -d)"
cleanup() {
    rm -rf "$SECRETS"
    agterm_cleanup_apple_creds
}
trap cleanup EXIT
agterm_require_developer_id
: "${SPARKLE_KEY_ITEM:?set AGTERM_SPARKLE_KEY_REF (1Password reference to the Sparkle EdDSA key) in scripts/maintainer.local}"
: "${APPLE_API_KEY:?notarization key missing}" "${APPLE_API_ISSUER:?}" "${APPLE_API_KEY_PATH:?}"

echo "Building $VERSION…"
swift test >/dev/null
scripts/bundle.sh >/dev/null
rm -rf "$OUT" && mkdir -p "$OUT"

echo "Notarizing (a few minutes)…"
ditto -c -k --keepParent dist/agterm.app "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" \
    --issuer "$APPLE_API_ISSUER" --wait
xcrun stapler staple dist/agterm.app
rm "$OUT/notarize.zip"
spctl --assess --type execute dist/agterm.app

ARCHIVE="$OUT/agterm-$VERSION.zip"
ditto -c -k --keepParent dist/agterm.app "$ARCHIVE"

echo "Signing the update and writing appcast.xml…"
op read "$SPARKLE_KEY_ITEM" > "$SECRETS/sparkle.key"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SECRETS/sparkle.key" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://agterm.xanom.co" "$OUT"
cp "$ARCHIVE" "$OUT/agterm.zip"

echo "Publishing $TAG…"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" --repo "$REPO" --title "agterm $VERSION" --generate-notes \
    "$ARCHIVE" "$OUT/agterm.zip" "$OUT/appcast.xml"
echo "Released https://github.com/$REPO/releases/tag/$TAG"
