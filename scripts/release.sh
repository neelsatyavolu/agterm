#!/bin/bash
# Publishes the version in ./VERSION as a GitHub release that Sparkle installs from.
# Usage: scripts/release.sh            (bump VERSION and commit first)
#        scripts/release.sh --dry-run  (build and write both appcasts in dist/release; publish nothing)
#
# Steps: Developer ID sign → notarize + staple → zip → EdDSA-sign for Sparkle → appcast.xml
# → GitHub release v<version> with agterm-<version>.zip, agterm.zip (stable name for the
# website) and appcast.xml (the feed every installed copy polls).
#
# A beta VERSION (1.1.0-beta.1) becomes a GitHub prerelease with only its zip: the stable feed
# (releases/latest/download/appcast.xml) skips prereleases, so stable users don't see it.
# Every release, stable or beta, then rewrites the beta feed: appcast.xml on the prerelease
# tagged beta-feed, which lists the newest beta and the newest stable build (items copied as
# generate_appcast signed them). Apps with a beta key read it (BetaChannel). A beta also
# replaces beta-feed's agterm.zip, the beta download link.
#
# --dry-run skips the clean-tree check, tests, Developer ID signing and notarization (the app is
# signed ad hoc), but EdDSA-signs with the real key, so the appcasts are what a release would publish.
# Needs the maintainer's 1Password items; see ~/Documents/GitHub/APPLE_SIGNING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "usage: scripts/release.sh [--dry-run]" >&2; exit 1 ;;
esac

REPO="neelsatyavolu/agterm"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
BETA_TAG="beta-feed"
OUT="dist/release"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
case "$VERSION" in *-beta.*) IS_BETA=1 ;; *) IS_BETA=0 ;; esac

if [ -n "$(git status --porcelain)" ]; then
    if [ "$DRY_RUN" = 1 ]; then
        echo "warning: uncommitted changes (a real release refuses them)" >&2
    else
        echo "error: commit your changes first (the release is built from the working tree)" >&2
        exit 1
    fi
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: $TAG already exists; bump VERSION" >&2
    exit 1
fi
# The release notes are this version's section of CHANGELOG.md (the app shows the same text).
NOTES="$(awk -v v="$VERSION" '/^## /{p=($2==v)} p' CHANGELOG.md | tail -n +2)"
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "error: CHANGELOG.md has no entries under \"## $VERSION\"; add them first" >&2
    exit 1
fi

echo "Loading signing and notarization credentials from 1Password…"
# shellcheck disable=SC1091
[ -f scripts/maintainer.local ] && source scripts/maintainer.local
SECRETS="$(mktemp -d)"
if [ "$DRY_RUN" = 1 ]; then
    unset APPLE_SIGNING_IDENTITY
    cleanup() { rm -rf "$SECRETS"; }
else
    # shellcheck disable=SC1091
    source scripts/load-apple-creds.sh
    cleanup() {
        rm -rf "$SECRETS"
        agterm_cleanup_apple_creds
    }
fi
trap cleanup EXIT
SPARKLE_KEY_ITEM="${AGTERM_SPARKLE_KEY_REF:-}"
: "${SPARKLE_KEY_ITEM:?set AGTERM_SPARKLE_KEY_REF (1Password reference to the Sparkle EdDSA key) in scripts/maintainer.local}"
if [ "$DRY_RUN" = 0 ]; then
    agterm_require_developer_id
    : "${APPLE_API_KEY:?notarization key missing}" "${APPLE_API_ISSUER:?}" "${APPLE_API_KEY_PATH:?}"
fi

echo "Building ${VERSION}…"
[ "$DRY_RUN" = 1 ] || swift test >/dev/null
scripts/bundle.sh >/dev/null
rm -rf "$OUT" && mkdir -p "$OUT"

if [ "$DRY_RUN" = 0 ]; then
    echo "Notarizing (a few minutes)…"
    ditto -c -k --keepParent dist/agterm.app "$OUT/notarize.zip"
    xcrun notarytool submit "$OUT/notarize.zip" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" \
        --issuer "$APPLE_API_ISSUER" --wait
    xcrun stapler staple dist/agterm.app
    rm "$OUT/notarize.zip"
    spctl --assess --type execute dist/agterm.app
fi

ARCHIVE="$OUT/agterm-$VERSION.zip"
ditto -c -k --keepParent dist/agterm.app "$ARCHIVE"

echo "Signing the update and writing appcast.xml…"
op read "$SPARKLE_KEY_ITEM" > "$SECRETS/sparkle.key"
"$SPARKLE_BIN/generate_appcast" --ed-key-file "$SECRETS/sparkle.key" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://agterm.xanom.co" "$OUT"
cp "$ARCHIVE" "$OUT/agterm.zip"

# The beta feed: this release's item plus the newest one of the other kind, taken from the
# feed that already lists it. Stable release: the beta in the current beta feed, if any.
# Beta: the latest release's (stable) item.
echo "Writing the beta feed…"
FEEDS="$SECRETS/feeds"
mkdir -p "$FEEDS" "$OUT/$BETA_TAG"
if [ "$IS_BETA" = 1 ]; then
    gh release download --repo "$REPO" --pattern appcast.xml --dir "$FEEDS"
    WANT_BETA=0
else
    gh release download "$BETA_TAG" --repo "$REPO" --pattern appcast.xml --dir "$FEEDS" 2>/dev/null || true
    WANT_BETA=1
fi
touch "$FEEDS/appcast.xml"
# <item> … </item> blocks; with want_beta=1 only those whose version has "-beta.".
awk -v want_beta="$WANT_BETA" '
    /<item>/ { inside = 1; block = "" }
    inside { block = block $0 "\n" }
    /<\/item>/ { inside = 0; if (!want_beta || block ~ /-beta\./) printf "%s", block }
' "$FEEDS/appcast.xml" > "$FEEDS/items.xml"
awk -v items="$FEEDS/items.xml" '
    /<\/channel>/ { while ((getline line < items) > 0) print line }
    { print }
' "$OUT/appcast.xml" > "$OUT/$BETA_TAG/appcast.xml"
if [ "$IS_BETA" = 1 ]; then cp "$ARCHIVE" "$OUT/$BETA_TAG/agterm.zip"; fi
echo "Beta feed lists: $(grep -o '<sparkle:shortVersionString>[^<]*' "$OUT/$BETA_TAG/appcast.xml" | sed 's/.*>//' | paste -sd ' ' -)"

if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run: wrote $OUT/appcast.xml and $OUT/$BETA_TAG/appcast.xml; published nothing."
    exit 0
fi

echo "Publishing ${TAG}…"
git tag "$TAG"
git push origin "$TAG"
if [ "$IS_BETA" = 1 ]; then
    gh release create "$TAG" --repo "$REPO" --title "agterm $VERSION" --notes "$NOTES" --prerelease --latest=false \
        "$ARCHIVE"
else
    gh release create "$TAG" --repo "$REPO" --title "agterm $VERSION" --notes "$NOTES" \
        "$ARCHIVE" "$OUT/agterm.zip" "$OUT/appcast.xml"
fi
if ! gh release view "$BETA_TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "$BETA_TAG" --repo "$REPO" --title "agterm beta feed" --prerelease --latest=false \
        --notes "The update feed for agterm beta testers, rewritten by every release. agterm.zip is the newest beta build."
fi
BETA_ASSETS=("$OUT/$BETA_TAG/appcast.xml")
if [ "$IS_BETA" = 1 ]; then BETA_ASSETS+=("$OUT/$BETA_TAG/agterm.zip"); fi
gh release upload "$BETA_TAG" --repo "$REPO" --clobber "${BETA_ASSETS[@]}"
echo "Released https://github.com/$REPO/releases/tag/$TAG"
