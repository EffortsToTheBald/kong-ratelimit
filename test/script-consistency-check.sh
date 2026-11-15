#!/usr/bin/env bash
# ============================================================
# script-consistency-check.sh —— Gate 6 task 3: Lua script dual-source consistency check
#
# Background: scripts have dual sources — the embedded string in
#       `kong/plugins/rate-limit-advanced/lib/redis.lua` (loaded at runtime via EVALSHA)
#       and the standalone `redis/*.lua` files (for bare redis-cli runs / matrix tests).
#       Their semantics must match.
# This check: extracts the embedded script literals and the corresponding files, then diffs
#       them byte-for-byte after stripping comments and blank lines.
#       Comments may differ between the two sources (the file version contains usage notes,
#       the embedded version contains review-number comments); code lines must match.
#       No runtime loading path is changed (pure read-only check).
# Usage: bash test/script-consistency-check.sh (needs python3, or works dependency-free
#       implemented with awk/grep, no python dependency)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIB=kong/plugins/rate-limit-advanced/lib/redis.lua
PASS=0; FAIL=0
ok()  { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }

# strip_code: strips Lua comments (-- to end of line) and blank lines, removes trailing whitespace
strip_code() {
    awk '{ sub(/--.*/, ""); sub(/[[:space:]]+$/, ""); } 1' "$1" \
        | sed '/^[[:space:]]*$/d'
}

# Temp dir: mktemp -d creates an independent directory, trap cleans it up (no pre-existing directory required)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_pair() { # check_pair <lua file name> <embedded variable name>
    local fname="$1" var="$2" tmp ftmp norm
    tmp="$WORK/emb.lua"
    # extract the embedded text between `local VAR = [[ ... ]]`
    awk -v var="$var" '
        $0 ~ ("local[[:space:]]+" var "[[:space:]]*=[[:space:]]*\\[\\[") { inblk=1; next }
        inblk && /\]\]/ { exit }
        inblk { print }
    ' "$LIB" > "$tmp"
    if [ ! -s "$tmp" ]; then
        bad "embedded script $var extraction failed (not found in lib/redis.lua)"
        return
    fi
    ftmp="$WORK/file.lua"
    norm="$WORK/embedded-norm.lua"
    strip_code "redis/$fname" > "$ftmp"
    strip_code "$tmp" > "$norm"
    if diff -q "$ftmp" "$norm" >/dev/null; then
        ok "consistent: redis/$fname <-> embedded $var (code lines identical after stripping comments/blank lines)"
    else
        bad "inconsistent: redis/$fname <-> embedded $var (diff below)"
        diff "$ftmp" "$norm" >&2 || true
        FAIL=$((FAIL+1))
    fi
}

check_pair token_bucket.lua TOKEN_BUCKET
check_pair multi_bucket.lua  GRANT_MULTI
check_pair grant_lease.lua   GRANT_LEASE
check_pair return_lease.lua  RETURN_LEASE

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
