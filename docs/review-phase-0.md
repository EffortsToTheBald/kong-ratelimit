# Phase 0 — Comprehensive Review of the Existing Implementation

**Review subject:** `kong-ratelimit/` (Kong 3.6.1 + Redis 7 + OpenResty)
**Review method:** static code review + runtime fact verification + post-mortem of incidents that already occurred
**Review date:** 2026-11-11
**Status:** review only; no code modified

---

## 0. Summary of Conclusions

1. **The core algorithm (Token Bucket) and the Redis atomic debit are correct**: read-compute-debit-write completes within a single EVAL; when multiple nodes share the same key, the total quota does not scale with node count. Already supported by measurement (450 requests → exactly 100 allowed).
2. **The real correctness risk lies not in the algorithm but in "state lifecycle"**: keys do not contain a policy fingerprint, so after a config change old buckets and old local inventory stay in effect. Measured `allowed=116 > limit=100`.
3. **The current default is Fail-Open, opposite to the new spec's Fail-Closed requirement**; and the test system cannot yet prove the core claim of "global quota" (per-node request counts are uncontrolled).

---

## 1. Review Scope and Runtime Verification

### 1.1 Files Checked

| File | Conclusion |
|---|---|
| `kong/plugins/rate-limit-advanced/handler.lua` | read, 71 lines |
| `kong/plugins/rate-limit-advanced/schema.lua` | read |
| `lib/algorithm.lua` | read, 154 lines (repo version matches the in-container version, 11-11 07:31) |
| `lib/redis.lua` | read, 129 lines |
| `lib/store.lua` | read, 87 lines |
| `redis/token_bucket.lua` | read (duplicates the embedded script) |
| `bench/common.sh` / `quota.sh` / `matrix.sh` | read |
| `k6/quota.js` / `latency.js` | read |
| `kong/kong.yml` | read |

### 1.2 Runtime Verification (measured this time, not inferred)

```
Kong version     : 3.6.1
Worker processes : 2 per node
lua_shared_dict  : kong_rl 32m  ← injected at nginx-kong.conf:36, confirmed effective
Plugin mount     : /usr/local/share/lua/5.1/kong/plugins/rate-limit-advanced (read-only)
Lua error logs   : no [error] on any of the three nodes
Redis key        : kong:rl:{rl:ip=172.20.0.1} (all three nodes share one key, as expected)
```

**This point matters**: local inventory indeed goes through the shared dict, so inventory is shared **per node** (2 workers share one copy), not one copy per worker. Worst-case hold = `node count × batch`, not `node count × worker count × batch`.

### 1.3 Deployment Drift (must be resolved first, otherwise later tests are untrustworthy)

The host machine's `/home/tdohs/kong/kong-ratelimit/bench/common.sh` is still the **old version**:

```bash
46:  "limit_by":["ip"],"namespace":"rl",...   ← namespace hardcoded
```

The repo version already uses a per-round independent namespace (5th argument). The old version makes **all rounds share the same bucket**, so leftover state from the previous round pollutes the next — the direct cause of the 116.

**Conclusion: before Phase 1 begins, the repo version must first be synced to the host machine; otherwise no test result is trustworthy.**

---

## 2. Module Review Table

| Module | Current Implementation | Issues | Risk | Suggested Fix |
|---|---|---|---|---|
| **Token Bucket** | `rate = limit/window` continuous refill; `burst=0` takes `limit`; fractional tokens supported; timing via Redis `TIME()` | ① On clock rollback, `ts` is overwritten with the smaller `now`; after rollback ends the same period is **billed twice**, granting extra tokens<br>② `X-RateLimit-Reset = now + window`; a token bucket has no "window reset" semantics<br>③ `burst` is unbounded; with `burst > limit`, bursts are uncontrolled<br>④ `Retry-After` is uncapped; with `limit=1/window=3600` it can reach 3600s | **P0**(①)<br>P1(②③④) | ① `ts` only moves forward (`ts = max(ts, now)`)<br>② reset becomes "time until the bucket refills" or "time until the next token is available"<br>③ validate `burst ∈ [1, K·limit]`<br>④ state an explicit cap and document it |
| **Redis Lua** | single EVAL completes HMGET→compute→HSET→PEXPIRE; on failure `close()`; on success `set_keepalive` | ① Return value only has a `tonumber` fallback; array length and `granted ≤ want` not validated<br>② Full script text uploaded every time (EVALSHA unused)<br>③ Depends on effects replication; with `lua-replicate-commands yes` it errors because `TIME` is non-deterministic<br>④ Docs must clarify "Lua atomicity ≠ strong consistency across failover" | P1 | ① Add defensive validation; treat any anomaly as a rejection<br>② `EVALSHA` + `NOSCRIPT` fallback<br>③ Note Redis config preconditions in README<br>④ See `design.md` §4.6 — wording already correct, keep it |
| **Local inventory** | `ngx.shared.kong_rl` shared across workers; `take()` uses `incr(-1)` with negative rollback; `fill()` uses `incr(+n)` + `expire` | ① When the shared dict is missing, degrades to a worker-private table with **no startup warning at all** (`backend()` never called)<br>② `fill()` is two non-atomic steps: an `incr` failure silently drops tokens (under-grant), no logging<br>③ When the dict is full, `incr` returns nil, also silent<br>④ Inventory TTL computed from the current `window`; not recomputed after config changes | P1/P2 | ① Validate in `init_worker` and `log.warn`<br>②③ On failure log errors and count<br>④ Resolve together with the policy fingerprint |
| **Batch** | when inventory is short, fetch `batch` from Redis; the current request uses 1, the rest stored locally | ① **Key lacks a policy fingerprint**: after a config change old inventory stays in effect, measured `116 > 100`<br>② `batch` is uncapped; with `batch > burst` a single node can drain a bucket in one shot<br>③ On node exit, unconsumed quota is lost outright, no reclamation<br>④ `batch=1` still goes through the local inventory branch; theoretically it could be "taken" by leftover inventory, failing the strict definition of "every request touches Redis" | **P0**(①④)<br>P1(②③) | ① Add `policy_version = hash(limit,window,burst,limit_by)` to the key<br>② Validate `batch ≤ burst`<br>③ State explicitly that there is no reclamation; document the loss bound<br>④ Short-circuit the local inventory for `batch==1`, go straight to EVAL |
| **Key** | `kong:rl:{namespace:dim=val:...}` using `{}` as hash tag; header values truncated at 256 | ① No policy version/fingerprint<br>② `path` dimension cardinality ungoverned (not normalized), easily blows up Redis memory<br>③ Multi-rule (one request, multiple buckets) unsupported<br>④ Missing dimensions uniformly filled with `-`, cannot distinguish "no header" from "empty header value" | **P0**(①)<br>P1(②③④) | ① Same as above; see `docs/key-design-phase-2.md`<br>② Path normalization (`/user/123 → /user/:id`)<br>③ Explicitly list as "not supported"<br>④ Use a separate sentinel for missing values and log it |
| **Failure handling** | `fault_tolerant=true` → fail-open + `X-RateLimit-Status: degraded`; `false` → 503 | ① **schema defaults to `true`, and `kong.yml` also sets `true`**, opposite to the new spec's "default Fail-Closed"<br>② The 429 path **logs nothing**; logs cannot distinguish "rate-limited rejection" from "Redis failure"<br>③ fail-open does not return `X-RateLimit-Limit`; response headers inconsistent<br>④ Config errors return 500, semantically close to 503 and easily confused | **P0**(①)<br>P1(②③④) | ① Default to `false`; sync docs and kong.yml<br>② Log info on 429 with key and limit<br>③ Unify response headers<br>④ Use 500 for config errors with a `detail` (current state acceptable; supplement docs) |
| **Dynamic config** | DB-less per-node `POST /config`; script arguments derived from `conf` each time | ① No atomic push; multiple nodes may be briefly inconsistent within the update window<br>② `limit/window/burst` changes do not isolate old buckets and old inventory<br>③ `limit_by` changes implicitly change keys, but old keys only vanish at TTL<br>④ The script only `warn`s on push failure, no `exit`; may silently partially succeed | **P0**(②)<br>P1(①③④) | ① Document the window-period semantics<br>② Policy fingerprint<br>③ Document it<br>④ Make the test script abort on failure |
| **Test system** | `quota.sh` (global quota), `matrix.sh` (batch×RPS), two k6 scripts | ① `k6/quota.js` picks nodes via `(__VU-1) % 3` with `shared-iterations`; **cannot guarantee exactly 150 per node** (the spec explicitly forbids substituting random assignment)<br>② No per-node statistics<br>③ No plugin-level metrics (Redis call count / local hit count / zero-grant count); only rough Redis `INFO` deltas<br>④ No fault injection, no soak tests, no node failure tests<br>⑤ Host scripts are the old version, inconsistent with the repo | **P0**(①⑤)<br>P1(②③④) | ① Switch to `per-vu-iterations` or split into 3 scenarios per node with fixed VU and iteration counts<br>② Output node-grouped statistics<br>③ Add counters in the plugin exposed via response headers/logs<br>④ See Phases 5 and 6<br>⑤ Sync first |

---

## 3. Detailed Key Issues

### 3.1 P0-1｜Keys lack a policy fingerprint → quota is "inherited" (measured)

**Symptom** (2026-11-11 13:35, measured by the user):

```
Config: limit=100 window=3600 burst=0 batch=20
Result: allowed=116  limited=334  total=450   ← over-granted by 16
```

**Investigation evidence**:

| Check Item | Result | Note |
|---|---|---|
| Plugin config across three nodes | identical `limit=100 window=3600 batch=20` | rules out config inconsistency |
| `failing open` logs | 0 | rules out degraded allowance |
| Redis key count | 1 | rules out key splitting |
| Redis bucket state | `tokens=0.7402`, `ts` ~30s before the check | bucket was drained exactly at test end |

**Arithmetic back-calculation**: before the test started, the bucket had been untouched for 15 hours; `refill` was capped by `burst=100` → starting at 100. During the test, refill at `rate=100/3600=0.028/s` added about 0.74. **This round Redis could emit at most 100.74 tokens, yet 116 were allowed.**

The extra 16 can only come from **tokens that already existed in local inventory before the test started** — fetched during the previous round's `limit=1000 / batch=auto` run and not fully consumed.

**Root cause**: Key = `kong:rl:{rl:ip=172.20.0.1}`, carrying no information about `limit/window/burst/batch`. After the policy changed, old buckets and old inventory still hit.

**This is not an algorithm defect** (the invariant "allowed ≤ issued" always holds), but a **state lifecycle defect**: the policy is "new", the state is "old".

**Impact**:
- Test results not reproducible (the same config produces different numbers on two runs)
- In production, when quotas shrink, already-issued inventory continues to allow for a while (docs mention it, but no isolation)

**Recommendation**: add `policy_version = short_hash(limit, window, burst, limit_by)` to the key. Any policy change becomes a new bucket; old buckets die out naturally by TTL. The cost is that at the instant of a quota change the bucket "refills"; this trade-off must be documented, and consider using `namespace` to let operators control it explicitly.

### 3.2 P0-2｜Default Fail-Open, opposite to the spec

`schema.lua`: `fault_tolerant = { type = "boolean", default = true }`
`kong.yml`: `fault_tolerant: true`

Current behavior: Redis unavailable → allow + `X-RateLimit-Status: degraded`.
Spec requires: default Fail-Closed (503).

**Impact**: rate limiting fails entirely during a Redis outage, and this is the "default" configuration, not an explicit choice.
**Recommendation**: change the default to `false`; sync `kong.yml`; update the trade-offs tables in README and `design.md` (the original text writes fail-open as "availability first by default").

### 3.3 P0-3｜IP dimension unconditionally trusts `X-Forwarded-For`

`algorithm.lua:22`:

```lua
return kong.client.get_forwarded_ip() or kong.client.get_remote_ip() or "unknown"
```

`get_forwarded_ip()` reads XFF, and Kong currently has no `trusted_ips` configured. A client can bypass IP-based rate limiting indefinitely by changing `X-Forwarded-For` on every request.

**Impact**: IP-dimension rate limiting is easily bypassed (security risk).
**Recommendation**: pick one of two explicit modes — (a) use only `get_remote_ip()`; (b) use the forwarded IP but require `trusted_ips` configuration and document the precondition.

### 3.4 P0-4｜Clock rollback causes "double-billed time"

`redis.lua:45-48,64`:

```lua
if now > ts then
  tokens = tokens + (now - ts) * rate
end
...
redis.call('HSET', key, 'tokens', tostring(tokens), 'ts', tostring(now))
```

If the Redis host clock rolls back (NTP step), `now < ts`:
1. This round does not refill (correct)
2. **But `ts` is written as the smaller `now`** (wrong)

After the clock returns to its original value, `now - ts` **counts the same period again**, fabricating `(ts_old - ts_new) × rate` extra tokens.

**Impact**: a rare over-grant path, but it violates the basic requirement of "never issue twice".
**Recommendation**: make `ts` monotonically increasing; on rollback do not update (`if now > ts then ... ts = now end`), and log one alert.

### 3.5 P0-5｜Tests cannot prove "fixed request count per node"

`k6/quota.js`:

```js
const node = NODES[(__VU - 1) % NODES.length];
...
executor: 'shared-iterations', vus: 30, iterations: 450
```

`shared-iterations` **dynamically** distributes 450 iterations across 30 VUs, each VU executing a different number of times; the node is decided by the VU number modulo. Therefore the actual request counts received by the three nodes are **not fixed** — possibly 148/151/151.

This directly conflicts with spec §7.2: "ensure the three nodes receive identical request volume; do not substitute random iteration assignment for fixed per-node request counts".

**Impact**: cannot strictly assert "150 per node", so "exactly 100 globally" can only serve as approximate evidence, not strong evidence.
**Recommendation**: change to three independent scenarios (each with fixed VU count + fixed iteration count), or `per-vu-iterations` with a VU count divisible per node.

### 3.6 P1｜`batch=1` does not short-circuit local inventory

Currently `algorithm.check()` unconditionally calls `store.take(key)` first. With `batch=1`, local inventory is theoretically always empty, but **if leftover inventory from a previous round exists**, the request would be taken by local inventory, so the baseline definition "every request touches Redis" no longer holds.

**Recommendation**: with `batch == 1`, skip `store.take/fill` and go straight to EVAL. This also makes the baseline readable at the code level.

### 3.7 P1｜`X-RateLimit-Reset` semantics mismatched

`reset = now + window`. A token bucket has no "window end" concept; this value gives clients no actionable guidance (by that time the bucket may or may not be full).

**Recommendation**: change to "time until the bucket recovers to full" or "time until the next token is available", consistent with the `Retry-After` convention.

### 3.8 P1｜`remaining` semantics inconsistent between the two paths

- fast path: returns the **local inventory** remainder (excludes global)
- slow path: returns the **Redis global** remainder

The same client sees the number jump between 19 → 980. Functionally harmless, but the external semantics are unclear and easily misread as a bug.

**Recommendation**: unify to "available from this node's perspective" or "global remaining", and distinguish in header naming (e.g., `X-RateLimit-Remaining-Local`).

---

## 4. Classified Issue List

### P0 — Must fix (blocks correctness/acceptance)

| Finding | Issue | Evidence |
|---|---|---|
| P0-1 | Keys lack a policy fingerprint; old buckets/old inventory stay in effect after config changes | measured 116 > 100 |
| P0-2 | Default Fail-Open, opposite to the spec's Fail-Closed | `schema.lua` default=true |
| P0-3 | IP dimension unconditionally trusts XFF; trusted_ips not configured | `algorithm.lua:22` |
| P0-4 | On clock rollback `ts` is overwritten, causing double-billed time | `redis.lua:64` |
| P0-5 | Tests cannot guarantee fixed per-node request counts | `k6/quota.js` |
| P0-6 | Host scripts inconsistent with the repo (namespace not parameterized) | `bench/common.sh:46` |

### P1 — Important (affects baseline trustworthiness or semantics)

| Finding | Issue |
|---|---|
| P1-1 | `batch=1` does not short-circuit local inventory; baseline impure |
| P1-2 | `X-RateLimit-Reset` does not match token bucket semantics |
| P1-3 | `remaining` semantics inconsistent between fast and slow paths |
| P1-4 | Missing `header_name` only returns 500 at runtime; schema does not validate |
| P1-5 | Redis return values lack defensive validation (length, `granted ≤ want`) |
| P1-6 | No per-node statistics or plugin-level metrics (Redis calls/local hits/zero grants) |
| P1-7 | 429 path has no logs; faults hard to distinguish from rejections |
| P1-8 | No alert when the shared dict degrades to a worker table (`backend()` never called) |
| P1-9 | `Retry-After` uncapped (can reach thousands of seconds at small rates) |
| P1-10 | EVALSHA unused; script text uploaded every time |

### P2 — Optimization (performance/maintainability)

| Finding | Issue |
|---|---|
| P2-1 | `store.fill` is two non-atomic steps (incr + expire); failures silent |
| P2-2 | No log or count when the shared dict is full |
| P2-3 | `redis/token_bucket.lua` duplicates the embedded script; dual sources easily drift |
| P2-4 | `matrix.sh`'s Redis ops statistics include other commands and k6 startup time; coarse |
| P2-5 | No `.gitignore`; `bench/out/` would enter version control |
| P2-6 | README's "one Redis access per N requests" is inaccurate (in reality "fetch a batch when inventory is short"; the average is 1/N) |
| P2-7 | No `init_worker`: no startup self-check, no connection warm-up |

---

## 5. Capabilities the Current Implementation Explicitly Does Not Support

Must be stated clearly, no ambiguity:

1. **One request constrained simultaneously by multiple independent rules** (Consumer global + Consumer×Path + IP + Route, "all satisfied before allowing").
2. **Atomic check and unified debit of multiple keys in a single Lua call** (Redis Cluster cross-slot restriction).
3. **A fixed "window reset" semantics** — this project is a token bucket; there is no top-of-hour reset.
4. **Strong consistency under Redis failover**: single-primary atomicity ≠ failover not losing writes.
5. **Reclamation of issued quota** (local inventory is not returned when a node exits).
6. **Atomic config push** (DB-less pushes per node; there is a brief inconsistency window).
7. **Path normalization / dimension cardinality governance**.

---

## 6. Capabilities Current Tests Cannot Yet Prove

| Claim | Current State | What's Missing |
|---|---|---|
| No over-granting under high concurrency | only one 30-VU round run | 10/50/100/200 concurrency matrix, repeated rounds |
| batch=N long-term correctness | only one 450-request round run | soak tests, multi-window recovery, node restarts |
| Redis failure behavior | code read only, not measured | stop Redis / timeout / auth failure / recovery |
| Quota loss on node failure | untested | stop node, restart, continue load |
| Dynamic config taking effect | verified once via manual curl | systematic tests + consistency-window observation |
| Behavior when the shared dict is full | untested | fill the 32m and observe degradation |
| Redis Cluster behavior | not deployed | cluster environment |
| Failover consistency boundary | untested | primary-replica + failover drills |

---

## 7. Suggested Refactor Order (mapping to later phases)

Strictly serial, each phase separately accepted:

| Phase | Content | Corresponding P0 |
|---|---|---|
| 1 (this report) | review | — |
| 2 | strict baseline: policy fingerprint, Fail-Closed default, clock rollback, batch=1 short-circuit, test script rework | P0-1/2/4/5/6 |
| 3 | key design and multi-rule assessment (documentation) | design basis for P0-1 |
| 4 | dimension verification, dynamic config, 429/503 semantics | P0-3, P1-4 |
| 5 | batch performance matrix + soak | P1-6 |
| 6 | exceptions and boundaries | all P1 |
| 7 | final performance and stability acceptance | — |

**Recommended before Phase 2**: sync the repo's `bench/` to the host machine (P0-6). Otherwise all later tests carry the old scripts' bias.

---

## 8. Appendix: Deployment Facts Discovered During This Review

| Item | Value | Impact |
|---|---|---|
| kong1 ports | 8030/8031 (not 8000) | Windows `iphlpsvc` occupies 8000 + WSL mirrored networking |
| Redis host port | 6380 (6379 in container) | a native redis-server already occupies 6379 on the host |
| Image source | pulled via the host proxy `127.0.0.1:7897` | no mirror used |
| k6 | v2.3.0 | scripts written for v0.4x, measured compatible |

These three port/network particularities must be written into the final document's "environment notes"; otherwise others reproducing will hit the same pitfalls.

---

**This phase ends. No code modified. Await confirmation before entering Phase 2.**
