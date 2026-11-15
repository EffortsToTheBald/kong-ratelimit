# Proposal

## Why

The Phase 0 review (`docs/review-phase-0.md`, 2026-11-11) confirmed that the token bucket algorithm and the Redis Lua atomic deduction are themselves correct, but 6 P0-severity defects prevent the project from meeting the acceptance criteria of `rule.md` §14—the most severe being "after a configuration change, the old Redis bucket and old local inventory are inherited by the new policy" (measured: allowed=116 > limit=100, a real over-admission) and "the default fail-open violates the established fail-closed policy". The phased plan of `rule.md` requires correctness before all performance optimization, so Phase 1 (the core correctness baseline) must come first. This change is that baseline.

## What Changes

- **Policy fingerprint in the key** (review finding P0-1, **BREAKING** key format): the rate-limiting key changes from `kong:rl:{rl:ip=…:path=…}` to `kong:rl:{rl:p=<8-char hash>:ip=…:path=…}`, where hash = FNV-1a(limit, window, burst(parsed), limit_by, header_name). Any policy change yields a new bucket; old buckets and old local inventory are naturally evicted by the existing TTL; cross-round/cross-configuration state inheritance is eliminated.
- **Fail-closed by default** (review finding P0-2, **BREAKING** default behavior): `schema.lua`'s `fault_tolerant` default changes true→false, and `kong/kong.yml` is set to false in sync; `fault_tolerant: true` is retained as the explicitly opted-in "admit + `X-RateLimit-Status: degraded`" mode.
- **Redis failure path fix**: remove the debug log in `algorithm.lua` that "dereferences `granted.granted` before checking for nil" (`rule.md` §9.1 issue A). Currently a Redis failure throws a Lua exception and returns 500, and the `fault_tolerant` branch is never reached; after the fix, failure returns nil by design and enters the fail-closed(503) / fail-open(degraded) branch.
- **Clock rollback does not double-bill** (review finding P0-4): in the Redis Lua script, `ts` is monotonic and does not go backward (it advances and is written back only when `now > ts`). The embedded script (`lib/redis.lua`) and the standalone script (`redis/token_bucket.lua`) are modified in sync.
- **batch=1 strict short-circuit**: when `batch=1`, the local inventory is skipped entirely (neither `store.take` nor `store.fill` runs); every request goes through one Redis EVAL, restoring the baseline definition "batch=1 = strict global consistency" (review finding P1-6, folded into this baseline).
- **Explicit IP dimension trust model** (review finding P0-3, qualitative correction): Kong defaults to trust none (with `trusted_ips` unconfigured, nginx realip does not rewrite `remote_addr`), so under the current deployment a spoofed `X-Forwarded-For` **cannot** bypass IP rate limiting—the original review judgment was too harsh. This item changes to: ① fix the non-existent PDK call `kong.client.get_remote_ip` in `algorithm.lua` (the PDK only has `get_ip()`; it is currently a potential nil call); ② document the IP value semantics (`get_forwarded_ip()` = the realip-processed `remote_addr`; forwarded headers are trusted only when `trusted_ips` is configured); ③ add a "spoofed XFF does not create a new bucket" regression test to pin down the default deployment behavior.
- **Load-test script convergence** (review finding P0-6 + wrapping up P0-5): `bench/common.sh`'s configuration generator gets a parameterized namespace (independent per round, preventing cross-round pollution) and is explicitly aligned to fail-closed; `bench/quota.sh` adds a per-node request count assertion (must equal PER_NODE exactly, otherwise the test fails).
- **Rollback baseline**: commit a git baseline commit before any modification (`rule.md` 15.1-10 "keep a rollback-able version per phase"; the repo currently has zero commits).

## Capabilities

### New Capabilities

- `rate-limiting`: the core behavior of multiple Kong nodes sharing a global token bucket quota—the bucket's policy identity (key fingerprint), the quota boundaries of batch=1 strict mode and batch=N lease mode, token refill and Redis time handling, default fail-closed on Redis failure, and the trust semantics of the IP dimension value.

### Modified Capabilities

(None—`openspec/specs/` is currently empty; this is the project's first capability spec.)

## Impact

- **Code**: `kong/plugins/rate-limit-advanced/{schema.lua, lib/algorithm.lua, lib/redis.lua}`; `redis/token_bucket.lua` (dual-source sync with the embedded script; the dual-source issue P2-3 is on record and not merged this phase)
- **Configuration**: `kong/kong.yml` (`fault_tolerant: false`); `docker-compose.yml` unchanged
- **Tests**: `k6/quota.js` (with the per-node assertion), `bench/{common.sh, quota.sh}`, a new spoofed-XFF scenario; produces `reports/phase-1-correctness.md` (the twelve-section format of `rule.md` §13; unexecuted tests must be marked NOT RUN)
- **Docs**: `README.md` (§7 acceptance list degraded row, §5 batch table), `docs/design.md` (§4.6/§7 failure modes, §9 trade-offs table, §12 key design)
- **Runtime impact**: the Redis key format changes (old keys expire naturally via the 2×window TTL, no migration needed); the Redis failure response changes from 500 to 503 (fail-closed default); the default failure behavior changes from "admit" to "reject"
- **Explicitly not doing** (left to later changes): P1 semantic items (unified reset/remaining basis, EVALSHA, Retry-After cap, response header unification), the batch performance matrix and inventory recovery (Phase 4), Prometheus metrics (Phase 5), multi-rule joint decision, path normalization
