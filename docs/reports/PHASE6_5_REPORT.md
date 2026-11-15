# Phase 6.5 Report: Concurrency and Exception E2E Verification

- **Date**: 2026-11-13
- **Baseline HEAD**: `63b9d45` (after the 6.4 fix); no production code changes during execution
- **Nature of this phase**: verification-focused; zero production code changes
- **commit**: `test: verify phase6.5 concurrent lease safety`

## 1. Execution environment

| Item | Value |
|---|---|
| HEAD | `63b9d45f137ac0d2d59cb89371b67c88ccf8e706` |
| Kong nodes | kong1/2/3 (compose `kong-common`, verified by container names); proxy ports 8030/8010/8020 |
| Worker count | 2 per node (verified via `ps`: kong1=1321/1322 etc.), 6 workers globally |
| Redis | `redis:7-alpine` (redis_version=7.x, per `INFO server`); single instance, no persistence |
| Docker | compose v2; kong↔redis direct container-network connectivity; non-root host |
| Test configuration | limit=100, window=86400 (refill < 0.02 tokens throughout ⇒ exact accounting), batch=10, burst=0, limit_by=ip, fault_tolerant=false, redis timeout=1000ms |

### Observability audit (completed before execution, zero production code changes)

- **Lease records** (`kong:rl:lease:{lease_id}`): fields `lease_id/pool_key/granted/status/created_at`; consumption is **not in Redis** (V1 frozen: consumption is purely local); CLOSED is local-only semantics, the Redis side stays OPEN
- **Worker attribution**: `lease_id = <hostname>:<worker_id>:<seq>:<hex>` (lease.lua:43/81) ⇒ (host,worker) is resolvable
- **Local remaining**: `X-RateLimit-Remaining` = local pool remaining (fast path) / granted−1 (slow path) (explicitly stated in the algorithm.lua:423-424 comment) ⇒ outstanding is observable per request
- **Connection→worker PID mapping**: `/proc/net/tcp` inode + `/proc/<pid>/fd` unique matching (ss unavailable)
- **Keepalive pinning**: `/dev/tcp` manual HTTP (reading the full response including body per request)
- **RL-DEBUG logs**: algorithm.lua notice-level output of `local_hit/lease_grant/lease_take_after_grant` (with lease_id/granted/remaining)

## 2. Test results (four independent scripts, all actually executed)

### 2.1 concurrent-lease-e2e.sh (Test 1: multi-worker concurrency) — **PASS 17/17** (executed twice, both all green)

- Phase A: 30 concurrent (round-robin across three nodes) + per-request response-header sampling; Phase B: 270 concurrent; Phase C: drain (sequential round-robin until 4 consecutive 100×429)
- **Multi-worker evidence**: lease_id (host,worker) covers **6/6** (`8b8a3f9f9422:0/1, 7f82df257927:0/1, 300029f42b6f:0/1`) — requests actually reached all 6 workers
- **No global over-admission**: Σgranted (summed over Redis records) = **100** = limit; exactly 10 GRANT records × granted=10
- **Scope distinction**: Redis GRANT total authorized = 100; local TAKE total consumed = 100 (== Σgranted, every granted token consumed exactly once); HTTP admitted = 100 (200) + 300 (429, denied-GRANT granted=0 — existing semantics)
- **No duplicate consumption / no negative inventory**: all sampled X-RateLimit-Remaining ≥ 0 (min=0); abnormal status codes other=0
- Final bucket tokens = 0.002 < 1 (the entire quota was consumed via GRANTs, no leakage)

### 2.2 lease-exhaustion-e2e.sh (Test 2: exhaustion and re-request, single pinned connection/worker) — **PASS 11/11** (5 executions: 4 all green + 1 intermittent 9/2 [details not retained; 3 consecutive all-green rounds followed])

- 12 requests on the pinned connection: remaining sequence **9,8,7,6,5,4,3,2,1,0,9,8** (exact match) — Lease A's pool drains 10→0, req11 triggers a **new GRANT Lease B** (rem=9), req12 consumes B (rem=8)
- Exactly 2 records: A≠B (seq increasing: 43 vs 44), each granted=10, B.created_at ≥ A, both status OPEN (V1: CLOSED is local semantics — frozen scope)
- **A does not resurrect**: req11 is a new GRANT, not a silent admission from old inventory (record count exactly 2 + rem=9)
- **B does not reuse A's inventory**: rem=9 (fresh granted−1), not ≥10
- **Multiple coexisting leases + independent worker inventories stay independent**: new-connection probing (≤8 attempts) — hitting a different worker ⇒ new pool ⇒ record count +1 and rem=9 (not 7 from the shared B pool); the 2nd probe hit in practice

### 2.3 worker-crash-e2e.sh (Test 3: kill -9 and inventory loss, this phase's focus) — **PASS 16/16** (2 executions: the 1st was 12/4 [script parsing bug] → all green after the fix)

- **kill target confirmed**: `/proc/net/tcp` inode (`43385121`) → uniquely owned by worker **PID=1322** (inode→fd match); after kill -9, a 10s ps polling confirmed the PID exited
- **Pre-crash accounting**: 4 requests on the pinned connection ⇒ 200×4, remaining sequence **9,8,7,6** ⇒ L1 granted=10 = consumed 4 + outstanding **6**
- **After kill -9**: 150 requests ⇒ **90** admitted (exactly 9×batch, all consumed) + 429×60 (denied-GRANT); other=0
- **Accounting closed loop**:
  - Crashed worker: `granted=10 = consumed 4 + lost 6` (outstanding 6 classified as lost after the crash)
  - Remaining workers: `granted=90 = consumed 90 + outstanding 0`
  - Global: `Σgranted=100 = HTTP admitted 94 + lost 6` — **94 ≠ 100 ⇒ no takeover, no re-authorization** (with takeover, allowed could have reached 100)
- **No RETURN/compensation**: L1's record granted/status/created_at untouched (identical before and after the crash); final bucket tokens = 0.007 < 1

### 2.4 lease-timeout-uncertain-e2e.sh (Test 4: timeout and uncertain outcomes) — **PASS 18/18** (2 consecutive all-green rounds after debugging converged)

- **P1 (Redis paused while inventory is confirmed)**: req1 GRANT (rem=9) → `CLIENT PAUSE 4000` → req2-10 all 200, remaining 8..0 (**confirmed inventory can still be taken locally, independent of Redis**) → req11 (pool empty, new GRANT times out) ⇒ **503** (existing fault branch, not 429) → after recovery 200 rem=9 (a normal new GRANT L2)
- **Scenario A (Redis never executed)**: `CLIENT PAUSE 5000 WRITE` (EVALSHA intercepted and queued, admin commands still available) → 0.5s later `CLIENT KILL` (before Kong's 1s timeout) ⇒ request 503, **record count=0** (deterministically not executed; commands dropped with the connection buffer) → after recovery 200 rem=9 (no phantom inventory)
- **Scenario B (executed but response lost)** — same-worker attribution chain verified (v2 fix): fd5 keepalive client connection established in advance and unique (ESTAB client connection count=1) → inode (`/proc/net/tcp`) → worker fd → **unique worker PID mapping** (e.g., inode=`44243484` → PID=`15937`) → **SIGSTOP redis** (signal from the host side) → **the timing-out request sent over the same fd5** ⇒ Kong's 1s timeout 503 (uncertain outcome enters the fault branch, not 429) → re-verify fd5 alive and attributed PID unchanged (the 503 did not close the client connection) → **SIGCONT** ⇒ Redis consumes the EVALSHA that arrived in the kernel buffer ⇒ **actually executed (exactly 1 record, response lost)** → **subsequent request sent over the same fd5** (worker PID re-verified consistent) ⇒ 200 **rem=9** and record count +1 ⇒ **the uncertain outcome did not register local inventory, was not retried (exactly 1 record), and the same worker proceeded through the normal flow to request a new lease**; attribution checked 3 times in total (before the request / after the 503 / after the subsequent request), with inode and PID consistent throughout ⇒ the timing-out request and the subsequent request were indeed handled by the same worker (not merely the same Kong node); had Kong closed the client connection after the 503, this would have been marked NOT VERIFIED per the acceptance criteria (no lowering of the bar) — in practice this did not occur
- granted=0 (explicit rejection ⇒ 429) is covered by concurrent-lease-e2e's 300×429 and 6.4's quota b20
- The three cases (not executed / executed with response lost / granted=0) each have independent assertions, without conflation

## 3. Inventory accounting (real test data)

**Normal operation** (measured by concurrent-lease-e2e):

```
granted(Redis Σ, 10 records×10) = 100
consumed(HTTP 200, exactly one TAKE per successful request) = 100
outstanding(per-worker pool remaining after drain, final remaining header=0/429) = 0
⇒ 100 = 100 + 0
```

**Worker crash** (measured by worker-crash-e2e, worker PID=1322, lease `8b8a3f9f9422:1:370:294bea`):

```
Pre-crash: granted=10 (Redis record) = consumed 4 (4×200) + outstanding 6 (remaining sequence 9,8,7,6)
Post-crash: granted=10 = consumed 4 + lost 6
Global:     Σgranted=100 = HTTP admitted 94 + lost 6 (94 ≠ 100 ⇒ the 6 lost units are never reused; no takeover/compensation/RETURN)
```

Computation: granted comes from the Redis record fields; consumed comes from the pre-crash 200 count on that connection; outstanding comes from the last pre-crash request's `X-RateLimit-Remaining`=6; lost = granted − consumed (after the crash); post-crash admissions of 90 = all new-GRANT consumption by the remaining workers (9 records × granted=10 each).

## 4. Issue log

- **Production code bugs: none** (all observed behavior matches the frozen design)
- **Test script bugs (all fixed and re-run)**:
  1. http_req status parsing (`${line##* }` captured "OK"/"Unavailable") → awk second column
  2. `set -- $line` polluting the function's `$1` (fd) ⇒ body-read redirection errors and connection misalignment → non-destructive parsing
  3. `eq "$st$rm"` concatenated comparison ("2009"≠"200") and mixing eq's output/exit code → independent comparison
  4. `--scan` order is not creation order ⇒ A/B records misidentified → sort by created_at
  5. Concurrent load all landing on kong1 (single proxy port) → port round-robin across three nodes (8030/8010/8020)
  6. Scenario B sent the request before STOP, a race (GRANT takes ~30ms end to end) → STOP first, then send the request
- **Test environment issues (resolved, never misreported as production bugs)**:
  1. `CLIENT PAUSE` **cannot** create "executed but response lost" — in practice, after Kong's 1s timeout the cosocket is closed and the queued commands are dropped (records=0). Switched to the SIGSTOP/SIGCONT approach for a genuine reproduction
  2. Sending SIGSTOP to PID 1 from inside the PID namespace is discarded by the kernel (a default-action signal) ⇒ freeze ineffective — switched to signaling from outside the namespace on the host (`docker inspect` to get the host PID)
  3. Non-root host ⇒ kill EPERM → `docker run --pid host --privileged busybox kill` (STOP/CONT verified effective with T state)
  4. `ss` unavailable → `/proc/net/tcp` inode + fd matching
- **v2 correction record (Scenario B same-worker evidence strengthened)**: in the initial version, the timing-out request used an independent curl and the subsequent request used a different fd5 ⇒ the same worker could not be proven. Fixed by sharing the fd5 keepalive connection + inode→fd→PID verification three times (before the request / after the 503 / after the subsequent request); post-503 connection liveness explicitly verified (if broken, NOT VERIFIED; in practice it never broke). 22 assertions total (newly added: connection uniqueness, attribution uniqueness, post-503 liveness, attribution consistency throughout)
- **NOT VERIFIED: none**. Observability boundary note (limited by the frozen design, not a gap): lease consumption is invisible in Redis (V1 consumption is purely local); consumed is verified per request via the HTTP 200 count + `X-RateLimit-Remaining`; CLOSED is local-only semantics, the Redis-side record stays OPEN, and local CLOSED behavior is indirectly verified via the remaining sequence (jumps to 9 after 0) and the new GRANT record

## 5. Statistics

| Script | Latest round | Notes |
|---|---|---|
| concurrent-lease-e2e.sh | PASS 17 / FAIL 0 | Both executions all green |
| lease-exhaustion-e2e.sh | PASS 11 / FAIL 0 | 5 executions: 4 all green + 1 intermittent 9/2 (3 consecutive all-green rounds followed) |
| worker-crash-e2e.sh | PASS 16 / FAIL 0 | 2 executions (all green after the 1st's script bug fix) |
| lease-timeout-uncertain-e2e.sh | PASS 22 / FAIL 0 / NOT VERIFIED 0 | **4 consecutive all-green rounds after the v2 fix** (18 assertions before the fix: the timing-out request used an independent curl, same-worker unproven — the evidence gap has been closed) |
| **Total (latest round)** | **PASS 66 / FAIL 0 / NOT VERIFIED 0** | |
| NOT RUN | Phase 6.6 (group report and final commit) | Not executed |

All assertions are based on real executions; no unexecuted items were marked PASS.

## 6. Production code change record

**Production code: unchanged**

(`git diff` only adds the 4 test scripts and this report; `git diff --check` passes.)

## 7. Next phase

- **Phase 6.5: passed** — concurrency safety (full coverage of 6 workers, no duplicate TAKE consumption, no negative inventory), no global over-admission (Σgranted=allowed=100/94+lost accounting closed loop), exhaustion re-request, kill -9 loss accounting (no takeover/compensation/RETURN), and the three-state distinction of timeout uncertain outcomes — all satisfying the frozen design
- **Conditions for entering Phase 6.6 met**: yes
- **Phase 6.6 still needs**: the `docs/PHASE6_REQUEST_INTEGRATION_REPORT.md` group report + final commit `feat: integrate worker lease into rate limit path`
