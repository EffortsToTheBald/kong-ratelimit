# Design

## Context

Status and constraints (motivation in proposal.md's Why):

- The code skeleton is settled: `handler.lua` (access decision/response) → `algorithm.lua` (key/decision) → `store.lua` (local inventory) + `redis.lua` (connection and the embedded token bucket Lua). `rule.md` 15.1 explicitly forbids rewriting the architecture, so this design is entirely **minimal modification**.
- `docs/review-phase-0.md` gives a P0×6 graded list; this design implements each item, and corrects the qualitative assessment of two of them per measured evidence (P0-3 XFF exploitability; P0-5 already fixed on the repo side, only the assertion wrap-up remains).
- PDK facts (verified against official Kong source/docs): `kong.client.get_forwarded_ip()` returns the realip-processed `ngx.var.remote_addr`; whether forwarded headers are trusted is decided by `trusted_ips`/`real_ip_header`/`real_ip_recursive`, with the default `trusted_ips = none` ⇒ not trusted. The PDK does **not** have a `get_remote_ip` function (the current code at `algorithm.lua:22` is a potential nil call).
- Verification environment: 3× Kong 3.6 DB-less (2 workers per node) + Redis 7 (docker compose); no front LB, fixed ports (8030/8010/8020); each test round requires `restart kong + FLUSHDB + independent namespace` (rule.md §12.1).
- The git repo currently has zero commits; a baseline must be committed before any modification (rule.md 15.1-10).

## Goals / Non-Goals

**Goals:**

- Close out all six P0 defects, plus two baseline accompaniments (nil dereference, batch=1 short-circuit), so that all "correctness"-related acceptance rows in rule.md §14 become provable.
- Each P0 fix comes with an executable test or regression scenario, producing `reports/phase-1-correctness.md`.
- Minimize changes: no module boundary changes, no response header structure changes, no TTL algorithm changes.

**Non-Goals:**

- P1 semantic unification (unified reset/remaining basis, EVALSHA, Retry-After cap, structured 429 logging)—left to later changes.
- The batch performance matrix, inventory recovery, adaptive batch (Phase 4).
- Prometheus metrics and structured logging (Phase 5).
- Multi-rule joint decision, path normalization, Redis Cluster/Sentinel deployment forms (a single Redis instance currently; hash tag semantics is for forward compatibility only).

## Decisions

### D1. Policy fingerprint: inputs, algorithm, and key layout (for review finding P0-1)

- **Inputs**: `limit`, `window`, `burst` (**parsed** values, with `burst=0` treated as `limit`, ensuring semantically equivalent configurations get the same bucket), `limit_by` (joined in configuration array order), `header_name` (participates only when `limit_by` includes `header`). **`batch` is excluded**.
- **Algorithm**: FNV-1a 32-bit, output as 8-char lowercase hex. About 10 lines of pure Lua, no new dependency (rule.md 15.1-5). The alternative of "encoding the full parameter string directly into the key" was rejected: the key would be too long and it is unnecessary; the "version number counter" was rejected: it requires cross-node shared incrementing state, introducing a new consistency problem.
- **Layout**: `kong:rl:{rl:p=<hex8>:ip=…:path=…}`. The `p=` element sits inside the hash tag after the namespace, keeping the `rule.md` §3.2 constraint "the complete rule identifier must be inside the hash tag" unchanged.
- **Why batch is excluded**: batch is a "transport parameter" (how much to claim at once) and does not change the bucket's identity; including it in the fingerprint would make any batch adjustment reset the whole bucket (meaninglessly clearing the global quota). The compatibility issue of old inventory with batch is covered by the batch=1 short-circuit (D4) plus the fingerprint jointly.
- **Cost (must be documented)**: a policy change ⇒ a brand-new bucket at full capacity. Operations that need "change limit but inherit the old remainder" should use `namespace` explicitly—that is the mechanism reserved by rule.md §3.4.

### D2. Fail-closed default (for review finding P0-2)

- `schema.lua`: `fault_tolerant` default `true → false`; `kong/kong.yml` explicitly set to `false` in sync; README §7 acceptance list and `docs/design.md` §9 trade-offs table rewritten in sync (the original text wrote fail-open as the default trade-off).
- The `fault_tolerant=true` behavior is fully preserved (admit + `X-RateLimit-Status: degraded`), only demoted from "default" to "explicit choice".
- The alternative of "controlling the default via an environment variable" was rejected: it adds configuration surface, and rule.md already fixes the policy direction.

### D3. Redis failure path fix (for rule.md §9.1 issue A)

- `algorithm.lua:check()`: move the nil check of `redis_mod.grant` **forward** to before any `granted.granted` dereference; on failure go `kong.log.err` + `return nil, err`. The RL-DEBUG debug log is retained but moved after the success path.
- The alternative of "wrapping the whole check in pcall" was rejected: it would also swallow genuine logic bugs into fail-open, masking problems.

### D4. batch=1 short-circuits local inventory (review finding P1-6 escalated)

- `check()` first does `resolve_batch`: when `batch == 1`, skip `store.take`/`store.fill`; every request goes through one EVAL.
- Rationale: restores the baseline definition "batch=1 = strict global consistency" (otherwise residual inventory could be "picked up", and the spec's "local inventory hit count is 0" could not be proven); it also eliminates the 60s tombstone key side effect under batch=1.
- The alternative of "relying on the D1 fingerprint's natural guarantee" was rejected: the fingerprint only isolates on configuration change and does not solve semantic purity within rounds of the same configuration.

### D5. Timestamp monotonicity (for review finding P0-4)

- Lua changes (the embedded script in `lib/redis.lua` + `redis/token_bucket.lua`, dual-source in sync; the P2-3 dual-source issue is not merged this phase):
  - Both the refill and the `ts` advance are folded into the `if now > ts` branch: `tokens = min(burst, tokens + (now-ts)*rate)`; `ts = now`;
  - When `HSET` writes back `ts`, write the **branch-internal ts value** rather than a bare `now`, ensuring `ts` is not overwritten during clock rollback.
- During rollback the bucket does not refill ⇒ under-admission; the error direction is consistent with the overall invariant (only under-admit, never over-admit).
- No server-side alert (Kong logs cannot be written from Lua); record this limitation in `reports/phase-1-correctness.md`.

### D6. Explicit IP dimension trust model (for review finding P0-3, qualitative correction)

- **Conclusion correction**: under the default deployment (`trusted_ips=none`), realip does not rewrite `remote_addr`, so a spoofed XFF **cannot** bypass IP rate limiting; the original review judgment "easily bypassable" was too harsh. The real problem is that the **semantics were not pinned down, and there is one dead-fallthrough**.
- Three changes:
  1. The fallthrough call at `algorithm.lua:22` is changed to the actually existing PDK `kong.client.get_ip()` (the direct peer, never spoofable), eliminating the potential nil call;
  2. Document the semantics: `get_forwarded_ip()` = the realip resolution result; upstream forwarded headers are trusted only after `trusted_ips` is configured—consistent with the IP determination basis of Kong's official rate-limiting plugin;
  3. A regression test pins the default behavior: the same source IP carrying different spoofed XFF values must hit the same bucket (the spec scenario "spoofed XFF does not create a new bucket").
- The alternative of "always using `get_ip()`" was rejected: it would break LB deployments where `trusted_ips` is configured (all traffic would be attributed to the LB IP); the alternative of "adding an `ip_source` configuration item" was rejected: it exceeds this phase's minimal-modification principle; recorded as P2.

### D7. Load-test script convergence (for review finding P0-6 + wrapping up P0-5)

- `bench/common.sh`: `kong_config_json` gains a namespace parameter (5th argument); `quota.sh`/`matrix.sh` generate an independent namespace per round (e.g., `rl-$(date +%s)`), eliminating buckets shared across rounds; the generated configuration explicitly sets `fault_tolerant:false`.
- `bench/quota.sh`: parse the k6 summary's `requests_kong1/2/3` counts, **must equal PER_NODE exactly or the script fails**—upgrading P0-5's "per-node request count is controllable" from a structural guarantee to a runtime assertion.
- Prior fact: the repo's `k6/quota.js` already uses `per-vu-iterations` + VU-to-node binding (`(__VU-1)%3`) + an ITER divisibility check, structurally already satisfying fixed allocation; no further changes needed.

### D8. Rollback baseline (rule.md 15.1-10)

- Before starting, `git add -A && git commit` to create the baseline (currently zero commits); also add `.gitignore` entries (`bench/out/`, `reports/` artifacts as needed) to keep test artifacts out of the baseline. After acceptance passes, commit the fix commit, forming two anchors that can be diffed/reverted.

## Risks / Trade-offs

- [Policy change means a full-capacity new bucket (a quota "reset")] → documented in README/design; `namespace` is the explicit escape hatch; the error direction is still "extra admission" rather than "uncontrolled over-admission" (capped by limit itself).
- [32-bit fingerprint collision] → negligible probability at the rule scale of a single project; if a bitwise collision appears, extend to 64-bit (layout unchanged, only hex length changes).
- [Default fail-closed lowers availability] → this is rule.md's established policy trade-off; `fault_tolerant=true` explicitly retained; docs updated in sync.
- [No refill during clock rollback causes under-admission] → consistent with the global error direction of "only under-admit, never over-admit"; the report records the "no server-side rollback alert" limitation.
- [Under batch=1, `X-RateLimit-Remaining` is always 0] → existing semantics (the slow path already returns granted−1); not changed this phase; handled when P1-3 unifies the basis.
- [quota.sh per-node assertion depends on k6 VU numbering order] → `per-vu-iterations` guarantees VUs 1..VUS start in order; if the assertion fails it precisely exposes the assumption being invalid, which is expected behavior (fail loudly).
- [Old and new keys coexist momentarily at upgrade] → DB-less configurations are deployed to the three nodes one by one; a second-scale window exists; the test procedure requires deploying all configurations before starting load (rule.md §12.1 restart+FLUSHDB already isolates this); old keys disappear with TTL ≤ 2×window.
- [Local environment quirks (WSL mirrored networking, ports 8030/6380, pulling images via a proxy)] → recorded in the review appendix; the report must include the environment notes, otherwise it cannot be reproduced.

## Migration Plan

1. Create the baseline commit (D8).
2. Code and configuration changes (D1–D7), self-tested item by item.
3. `docker compose restart kong1 kong2 kong3` → wait for Kong readiness → `FLUSHDB` → deploy the new configuration to the three nodes → run rule.md Phase 1 tests A/B/C/D and the new regression scenarios in sequence.
4. Produce `reports/phase-1-correctness.md` (the twelve-section format of rule.md §13; unexecuted tests marked NOT RUN, fabrication forbidden).
5. Rollback strategy: `git revert` to the baseline commit restores the status quo; the new key format has no persistence migration issue (Redis has no AOF/RDB, `--save ""`); old-format keys disappear naturally via TTL.

## Open Questions

(None blocking. Implementation details such as fingerprint hex length and tombstone TTL are decided during coding and do not affect the spec or task breakdown.)
