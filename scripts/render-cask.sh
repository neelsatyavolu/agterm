#!/bin/bash
# Prints the Homebrew cask (packaging/homebrew/agterm.rb) for a release zip.
# Usage: scripts/render-cask.sh <version> <path to agterm-<version>.zip>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/render-cask.sh <version> <zip>}"
ZIP="${2:?usage: scripts/render-cask.sh <version> <zip>}"
case "$VERSION" in
    *[!0-9A-Za-z.-]*) echo "error: unexpected version \"$VERSION\"" >&2; exit 1 ;;
esac
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/agterm.rb
