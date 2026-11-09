#!/bin/bash
# Renders the agterm.dev screenshots with the debug app's showcase self-test (SelfTest.showcase and
# SelfTestSite.swift): four small git repos with a stand-in `claude`, so agterm measures real diffs.
# Usage: scripts/site-shots.sh [out-dir]   (default .build/site-shots). Copy the PNGs you want into site/.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mkdir -p "${1:-.build/site-shots}" && cd "${1:-.build/site-shots}" && pwd)"
DIR="$OUT/fixture"
rm -rf "$DIR" && mkdir -p "$DIR/fakes"

# The stand-in agent: a compiled program named claude (agterm knows agents by process name).
# `claude <session id> <seconds busy> <seconds in all>` writes Claude Code's record of a running
# session, ~/.claude/sessions/<pid>.json, busy and then idle, and removes it when it stops.
cat > "$DIR/fakes/claude.c" <<'EOF'
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static char record[PATH_MAX];
static void stop(int s) { (void)s; unlink(record); _exit(0); }
static void put(const char *id, const char *status) {
    FILE *f = fopen(record, "w");
    if (f) { fprintf(f, "{\"sessionId\":\"%s\",\"status\":\"%s\"}\n", id, status); fclose(f); }
}
int main(int c, char **v) {
    if (c < 4) return 2;
    snprintf(record, sizeof record, "%s/.claude/sessions/%d.json", getenv("HOME"), (int)getpid());
    signal(SIGTERM, stop); signal(SIGHUP, stop); signal(SIGINT, stop);
    int busy = atoi(v[2]), all = atoi(v[3]);
    put(v[1], busy > 0 ? "busy" : "idle");
    if (busy > 0) { sleep(busy); put(v[1], "idle"); }
    if (all > busy) sleep(all - busy);
    stop(0);
}
EOF
mkdir -p "$HOME/.claude/sessions"
cc -o "$DIR/fakes/claude" "$DIR/fakes/claude.c"

repo() {  # repo <name> <branch>
    mkdir -p "$DIR/$1/src" && git -C "$DIR/$1" init -q -b "$2"
}
commit() { git -C "$DIR/$1" add -A && git -C "$DIR/$1" -c user.name=demo -c user.email=demo@example.com commit -qm init; }

repo web main
mkdir -p "$DIR/web/src/auth"
cat > "$DIR/web/src/auth/redirect.ts" <<'EOF'
import { next } from "../router"
import { clearSession } from "./session"

// Where people land after signing in or out.

export function afterSignOut() {
  clearSession()
  return next("/")
}

export function loginURL(from: string) {
  const url = new URL("/login", location.origin)
  if (from !== "/") url.searchParams.set("to", from)
  return url
}

// Sends a signed-in user on to the page they asked for.
export function afterSignIn(url: URL) {
  return next(url.searchParams.get("to"))
}
EOF
commit web

repo api env-rename
for i in $(seq 1 18); do echo "export const v$i = process.env.WORKER_SETTING_$i"; done > "$DIR/api/src/env.ts"
commit api

repo design tokens
for i in $(seq 0 59); do echo "export const line$i = $i"; done > "$DIR/design/src/base.ts"
commit design

repo docs main
echo "# Docs" > "$DIR/docs/README.md"
commit docs

# What the first tab's terminal shows: a Claude Code session mid-task.
E=$'\033'
G="$E[32m●$E[0m"; B="$E[1m"; D="$E[2m"; R="$E[0m"
cat > "$DIR/demo.ans" <<EOF
${D}>${R} the login page bounces back to /login after sign-in

$G I'll trace the redirect. Reading the session middleware first.

$G ${B}Read${R}(src/auth/session.ts)
  ${D}⎿  Read 84 lines${R}
$G ${B}Search${R}(pattern: "next\\(", path: "src/auth")
  ${D}⎿  Found 3 files${R}

$G The callback trusts the ${B}?to=${R} parameter even when it points back at /login,
  so a signed-in user is sent straight back to the form. Fixing the guard:

$G ${B}Update${R}(src/auth/redirect.ts)
  ${D}⎿  Updated src/auth/redirect.ts with 4 additions and 1 removal${R}
      18   export function afterSignIn(url: URL) {
      19 $E[41;97m-   return next(url.searchParams.get("to"))$R
      19 $E[42;30m+   // Never send a signed-in user back to the form.$R
      20 $E[42;30m+   const to = url.searchParams.get("to") ?? "/"$R
      21 $E[42;30m+   if (to.startsWith("/login")) return next("/")$R
      22 $E[42;30m+   return next(to)$R
      23   }

$G ${B}Bash${R}(npm test -- auth)
  ${D}⎿  ✓ redirect after sign-in (12 ms)${R}
     ${D}✓ keeps ?to= for other pages (3 ms)${R}
     Tests  14 passed (14)

$E[34m◐$R ${D}Checking the sign-out path too… (18s · ↓ 2.4k tokens)${R}
EOF

swift build
rm -f "$OUT"/showcase*.png
AGTERM_SELFTEST="$OUT" AGTERM_SHOWCASE="$DIR" AGTERM_FAKE_AGENTS="$DIR/fakes" .build/debug/AgTerm
ls "$OUT"/showcase*.png
