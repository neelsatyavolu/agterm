#!/bin/bash
# Makes agmux's analytics-service accept every agent and feature agterm reports.
# Usage: scripts/analytics-sync.sh [--dry-run] <path to agmux/analytics-service>
#
# Writes docs/analytics-allowlist.json (kept current by AnalyticsTests) into AGTERM_AGENTS and
# AGTERM_FEATURES in the service's src/validate.ts. If that changes anything, it runs the
# service's typecheck and tests, deploys it with wrangler (already signed in), and commits and
# pushes validate.ts in the agmux repo. Nothing to change: it does nothing. --dry-run prints
# the new lists and leaves everything as it was. scripts/release.sh runs it when
# AGTERM_ANALYTICS_SERVICE is set in scripts/maintainer.local.
set -euo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
SERVICE="${1:?usage: scripts/analytics-sync.sh [--dry-run] <path to agmux/analytics-service>}"
LIST="$(cd "$(dirname "$0")/.." && pwd)/docs/analytics-allowlist.json"
VALIDATE="$SERVICE/src/validate.ts"
[ -f "$VALIDATE" ] || { echo "error: no $VALIDATE" >&2; exit 1; }

REPO="$(git -C "$SERVICE" rev-parse --show-toplevel)"
if [ -n "$(git -C "$REPO" status --porcelain -- "$VALIDATE")" ]; then
    echo "error: $VALIDATE has uncommitted changes; commit or discard them first" >&2
    exit 1
fi

# Rewrites the two Set literals; prints "changed" or "same".
RESULT="$(node - "$LIST" "$VALIDATE" "$DRY" <<'NODE'
const fs = require("fs");
const [list, file, dry] = process.argv.slice(2);
const { agents, features } = JSON.parse(fs.readFileSync(list, "utf8"));
const ok = (ids) => Array.isArray(ids) && ids.every((id) => /^[a-z0-9_-]{1,32}$/.test(id));
if (!ok(agents) || !ok(features)) throw new Error("allow-list ids must be 1-32 of a-z, 0-9, _ and -");
const literal = (ids) => {
  const lines = [];
  let line = "  ";
  for (const id of ids) {
    const word = JSON.stringify(id) + ", ";
    if (line.length + word.length > 100) { lines.push(line.trimEnd()); line = "  "; }
    line += word;
  }
  lines.push(line.trimEnd());
  return "new Set([\n" + lines.join("\n") + "\n])";
};
let text = fs.readFileSync(file, "utf8");
const before = text;
for (const [name, ids] of [["AGTERM_AGENTS", agents], ["AGTERM_FEATURES", features]]) {
  const pattern = new RegExp(`(export const ${name} = )new Set\\(\\[[\\s\\S]*?\\]\\)`);
  if (!pattern.test(text)) throw new Error(`${name} not found in ${file}`);
  text = text.replace(pattern, `$1${literal(ids)}`);
}
if (text === before) { console.log("same"); process.exit(0); }
if (dry === "1") { console.error(text.match(/export const AGTERM_AGENTS[\s\S]*?AGTERM_FEATURES[\s\S]*?\]\)/)[0]); }
else fs.writeFileSync(file, text);
console.log("changed");
NODE
)"

if [ "$RESULT" = "same" ]; then
    echo "Analytics service already accepts every agterm agent and feature."
    exit 0
fi
if [ "$DRY" = 1 ]; then
    echo "Dry run: the lists above would be written to $VALIDATE and deployed."
    exit 0
fi

echo "Updated the allow-lists in $VALIDATE; checking and deploying…"
restore() { git -C "$REPO" checkout -- "$VALIDATE"; }
( cd "$SERVICE" && npm run --silent typecheck && npm test --silent ) || { restore; echo "error: the service's checks failed; left it as it was" >&2; exit 1; }
( cd "$SERVICE" && npx wrangler deploy ) || { restore; echo "error: wrangler deploy failed; left it as it was" >&2; exit 1; }
git -C "$REPO" add -- "$VALIDATE"
git -C "$REPO" commit -m "feat(analytics): accept agterm's current agents and features" -- "$VALIDATE"
git -C "$REPO" push
echo "Deployed and pushed the analytics service's agterm allow-lists."
