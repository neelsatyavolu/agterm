#!/bin/bash
# Makes beta keys: a tester pastes one into Settings → General → Updates to get beta builds.
# Usage: scripts/beta-key.sh [--days N] <tester name>   prints a key (no expiry without --days)
#        scripts/beta-key.sh --init                     creates the signing key pair, once
#
# A key is the tester's name, the issue date and the expiry, signed with an Ed25519 key kept in
# 1Password (Private vault, maintainer's account). The app checks keys with the public half,
# BetaChannel.publicKey. The private key goes from scripts/beta-key.swift to 1Password and back
# through pipes only: it is never printed or written to disk.
set -euo pipefail
cd "$(dirname "$0")/.."

ACCOUNT="E3OXZANXQRDOBNXQMPXZ6YBHTY"
VAULT="Private"
ITEM="agterm Beta Key Signing Key"
SWIFT_TOOL="scripts/beta-key.swift"

usage() {
    echo "usage: scripts/beta-key.sh [--days N] <tester name> | --init" >&2
    exit 1
}

init() {
    if op item get "$ITEM" --vault "$VAULT" --account "$ACCOUNT" >/dev/null 2>&1; then
        echo "error: 1Password already has \"$ITEM\" in $VAULT; a new pair would void every key made so far" >&2
        exit 1
    fi
    local template public stored id
    # Held in memory, so op never sees a half-written template; printf is a builtin (no argv).
    template="$(swift "$SWIFT_TOOL" new-item "$ITEM")"
    printf '%s' "$template" | op item create --account "$ACCOUNT" --vault "$VAULT" - >/dev/null
    template=""
    public="$(op read --account "$ACCOUNT" "op://$VAULT/$ITEM/public key")"
    # The private key read back must give the same public key.
    stored="$(op read --account "$ACCOUNT" "op://$VAULT/$ITEM/password" | swift "$SWIFT_TOOL" public)"
    if [ "$public" != "$stored" ]; then
        echo "error: the key read back from 1Password doesn't match; check \"$ITEM\"" >&2
        exit 1
    fi
    id="$(op item get "$ITEM" --vault "$VAULT" --account "$ACCOUNT" --format json | jq -r .id)"
    echo "Created 1Password item \"$ITEM\" ($id) in $VAULT."
    echo "Public key (put it in BetaChannel.publicKey): $public"
}

sign() {
    local name="$1" days="${2:-}"
    op read --account "$ACCOUNT" "op://$VAULT/$ITEM/password" | swift "$SWIFT_TOOL" sign "$name" ${days:+"$days"}
}

DAYS=""
NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --init) [ $# -eq 1 ] && [ -z "$NAME$DAYS" ] || usage; init; exit 0 ;;
        --days) [ $# -ge 2 ] || usage; DAYS="$2"; shift 2 ;;
        -*) usage ;;
        *) [ -z "$NAME" ] || usage; NAME="$1"; shift ;;
    esac
done
[ -n "$NAME" ] || usage
sign "$NAME" "$DAYS"
