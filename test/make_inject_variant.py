#!/usr/bin/env python3
"""Generate the "failure after commit point" injection variant of RETURN_LEASE:
   inject redis.error_reply after the idempotent commit point (the RETURNED marker)
   but before the bucket update, to deterministically verify "mark succeeded,
   bucket update failed ⇒ retry does not double-return".
   Test-only purpose: the test variant is modified, the production script is untouched."""
import sys

SRC = "redis/return_lease.lua"
ANCHOR = "redis.call('HSET', lkey, 'status', 'RETURNED', 'return_requested', requested)"

src = open(SRC, encoding="utf-8").read()
if ANCHOR not in src:
    sys.exit("anchor not found in " + SRC)
injected = src.replace(
    ANCHOR,
    ANCHOR + '\ndo return redis.error_reply("INJECTED_FAILURE") end',
    1,
)
out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/rl_inject.txt"
open(out, "w", encoding="utf-8").write(injected)
print("variant ok ->", out)
