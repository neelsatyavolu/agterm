#!/bin/bash
# Builds agterm, signs it with the Developer ID certificate from 1Password, and installs it to
# /Applications. Usage: ./install.sh [--open] [--adhoc]
# --adhoc skips 1Password and signs ad hoc (works on this Mac only).
# Signing setup: ~/Documents/GitHub/APPLE_SIGNING.md; local settings in scripts/maintainer.local.
set -euo pipefail

cd "$(dirname "$0")"
SOURCE="dist/agterm.app"
DEST="/Applications/agterm.app"

OPEN=0
ADHOC=0
for arg in "$@"; do
    case "$arg" in
        --open) OPEN=1 ;;
        --adhoc) ADHOC=1 ;;
        *) echo "error: unknown option $arg" >&2; exit 1 ;;
    esac
done

if [ "$ADHOC" = 0 ]; then
    echo "Loading the Developer ID certificate from 1Password…"
    # shellcheck disable=SC1091
    [ -f scripts/maintainer.local ] && source scripts/maintainer.local
    # shellcheck disable=SC1091
    source scripts/load-apple-creds.sh
    trap agterm_cleanup_apple_creds EXIT
    agterm_disable_notarization_env
    agterm_require_developer_id
fi

echo "Building…"
scripts/bundle.sh >/dev/null

# The app itself, not the sessions helper (the same executable run with --sessions-helper),
# which keeps tabs running after a quit.
if pgrep -lf "$DEST/Contents/MacOS/agterm( |$)" | grep -v -e "--sessions-helper" >/dev/null; then
    echo "error: agterm is running from $DEST. Quit it (⌘Q) and run this again. Its tabs keep running in the sessions helper and come back when agterm starts; agterm → Quit and End Sessions ends them instead." >&2
    exit 1
fi

echo "Installing to ${DEST}…"
# Only ever removes the previous install of this app.
[ -d "$DEST" ] && rm -rf "$DEST"
ditto "$SOURCE" "$DEST"
touch "$DEST"

codesign --verify --strict "$DEST"
codesign -dvv "$DEST" 2>&1 | sed -n '/^Authority=Developer ID Application/p;/^Signature=adhoc/p' | head -1
echo "Installed $DEST"

if [ "$OPEN" = 1 ]; then
    open "$DEST"
fi
