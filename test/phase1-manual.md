# Manual Test Record & Playbook — Phase 1 Core Correctness Baseline (first-commit)

**Date**: 2026-11-11
**Executor**: project author (each case executed manually per this playbook)
**Conclusion**: ✅ **all passed** (environment setup + 11 cases, no failures)
**Corresponding change**: `openspec/changes/phase1-correctness-baseline` (22/22 tasks, commit chain `3d06fdf..41b10f9`)
**Automated acceptance report**: `reports/phase-1-correctness.md` (this document is the manual recheck and reproducible playbook for that report)

---

## 1. Result Summary

| # | Case | Acceptance points | Result |
|---|---|---|---|
| 1 | Single-node basic token bucket (limit=5/60s) | First 5 requests 200, from the 6th onward 429; the 429 carries `Retry-After` (≈11–12s) and `X-RateLimit-*` headers | ✅ |
| 2 | batch=1 strict quota across three nodes | 100/350/0; per-node 150 assertion passed; logs `local_hit=0`, `local_fill=0`, `redis_grant=450` | ✅ |
| 3 | batch=20 no over-issue and lower bound | allowed ∈ [40,100] and never exceeds 100; stable at 100 under the isolation protocol, historical fluctuation not reproduced | ✅ |
| 4 | Cross-config isolation (policy fingerprint) | Same namespace, after switching limit 1000→100 exactly ≤100 allowed (116 in the same scenario before the fix); KEYS shows two distinct `p=` buckets | ✅ |
| 5 | Redis failure defaults to Fail-Closed | 503 `rate limiter unavailable`; no upstream response headers; log `failing closed`, no traceback/500 | ✅ |
| 6 | Explicit fault tolerance, degraded | 200 + `X-RateLimit-Status: degraded` + request reached upstream; no marker after recovery; log `failing open` | ✅ |
| 7 | Token refill (rate=1/s) | After exhaustion, wait 5s: exactly 4–5 200s (=⌊elapsed×rate⌋); bucket tokens ≤ burst=60 | ✅ |
| 8 | Clock rollback causes no double refill | Pre-set a future ts → after the request tokens −1, **ts keeps its future value and is not overwritten**, no refill | ✅ |
| 9 | Forged XFF does not switch bucket | `bench/xff.sh`: 200=1, 429=19, PASS | ✅ |
| 10 | namespace round isolation + per-node assertion | The two rounds have different namespace segments and the same policy fingerprint (e891f3c2); assertion 10/10/10 passed | ✅ |
| 11 | Fingerprint properties (10 assertions) | `FINGERPRINT_PROPS_OK base=25c15179 limit1000=8039753e` | ✅ |

---

## 2. Environment Setup and Isolation Preamble

```bash
cd /home/tdohs/kong/kong-ratelimit

# docker permissions: if you get permission denied, run newgrp docker once or reopen the terminal (usermod already applied)
docker compose ps                              # expect: 5 containers running / healthy
docker compose exec redis redis-cli ping       # expect: PONG
```

**Isolation preamble (run at the start of every Case):**

```bash
docker compose restart kong1 kong2 kong3
sleep 20 && curl -s -o /dev/null -w 'kong1 ready: %{http_code}\n' localhost:8031/status   # expect 200
docker compose exec redis redis-cli FLUSHDB          # expect OK
```

> `bench/common.sh` contains bash arrays and **must be sourced in bash** (zsh will error).
> To restore the initial config after testing: `restart kong×3` returns to `kong.yml` (limit=1000/60s, batch=auto, fault_tolerant=false).

---

## 3. Detailed Case Playbook (commands + acceptance + results)

### Case 1｜Single-node basic token bucket (with Retry-After)

```bash
source bench/common.sh
apply_config "$(kong_config_json 5 60 1 true manual-c1)"    # limit=5/60s, batch=1
sleep 2
for i in $(seq 1 8); do curl -s -o /dev/null -w '%{http_code} ' localhost:8030/echo; done; echo
curl -is localhost:8030/echo | head -8                       # inspect the 429 response headers of the 6th request
```

**Acceptance**:
- [x] First 5 requests `200`, the 6th–8th `429`
- [x] The 429 response contains `Retry-After` (≈11–12s = (1−tokens)/rate, rate=5/60) and `X-RateLimit-*` headers
- [x] 429 response body JSON: `{"message":"API rate limit exceeded",...}`

**Result: ✅ PASS**

### Case 2｜batch=1 strict global quota across three nodes (tests A+B)

```bash
./bench/quota.sh -l 100 -b 1 -p 150        # note the namespace=rl-xxxx printed in the output
NS=<replace with the namespace printed above>
docker compose logs kong1 kong2 kong3 | grep "$NS" > /tmp/c2.log
grep -c local_hit  /tmp/c2.log             # expect 0
grep -c local_fill /tmp/c2.log             # expect 0
grep -c redis_grant /tmp/c2.log            # expect 450
```

**Acceptance**:
- [x] `allowed=100 limited=350 other=0 total=450`
- [x] `per-node request count assertion passed: kong1/2/3 each 150 requests`
- [x] Logs: `local_hit=0`, `local_fill=0`, `redis_grant=450` (every request went through Redis, none drew from the local lease pool)

**Result: ✅ PASS**

### Case 3｜batch=20 no over-issue and lower bound

```bash
./bench/quota.sh -l 100 -b 20 -p 150       # run several rounds; do the isolation preamble before each round
```

**Acceptance**:
- [x] Every round `allowed ∈ [40, 100]` and never > 100 (no over-issue)
- [x] `other=0`, per-node assertion passed
- [x] Under the isolation protocol every round is stable at 100 (the historical 10/82/45 fluctuation came from cross-round contamination, not reproduced)

**Result: ✅ PASS**

### Case 4｜Cross-config isolation (policy fingerprint, key case)

```bash
# Same namespace, two consecutive rounds with different limits (cannot use quota.sh, it switches namespace each round):
source bench/common.sh
NS=manual-c4
apply_config "$(kong_config_json 1000 3600 20 true "$NS")"; sleep 2
for p in 8030 8010 8020; do for i in $(seq 1 150); do curl -s -o /dev/null -w '%{http_code}\n' localhost:$p/echo; done; done | sort | uniq -c
# ↑ takes about 30–45s, expect 450 x 200

apply_config "$(kong_config_json 100 3600 20 true "$NS")"; sleep 2     # switch limit under the same namespace
for p in 8030 8010 8020; do for i in $(seq 1 150); do curl -s -o /dev/null -w '%{http_code}\n' localhost:$p/echo; done; done | sort | uniq -c

docker compose exec redis redis-cli KEYS 'kong:rl:*manual-c4*'
```

**Acceptance**:
- [x] Second round `200 ≤ 100` (measured **116** over-issued in the same scenario before the fix)
- [x] KEYS shows two keys: same namespace, different `p=` fingerprints (`8039753e` / `50780f62`)
- [x] The limit=100 bucket's tokens driven to ≈0

**Result: ✅ PASS**

### Case 5｜Redis failure → default Fail-Closed (503)

```bash
source bench/common.sh
apply_config "$(kong_config_json 100 3600 1 true manual-c5)"; sleep 2
docker compose stop redis
curl -is localhost:8030/echo | head -6
docker compose logs kong1 --since 2m | grep -E "failing|grant failed" | tail -2
docker compose start redis
```

**Acceptance**:
- [x] HTTP **503**, response body `{"message":"rate limiter unavailable"}`
- [x] Response has no `X-App-Name`/`X-App-Version` (request did not reach upstream)
- [x] Logs `redis grant failed` (error) + `failing closed`, no `stack traceback` / `attempt to index`
- [x] One curl to each of the three nodes, all 503

**Result: ✅ PASS**

### Case 6｜Redis failure → explicit fault tolerance (degraded pass-through)

```bash
# The config must explicitly carry fault_tolerant:true (what kong_config_json generates is explicitly false), so build it by hand:
source bench/common.sh
JSON=$(python3 -c "
import json
cfg={'limit':100,'window':3600,'batch':1,'limit_by':['ip'],'namespace':'manual-c6','fault_tolerant':True,'redis':{'host':'redis','port':6379,'database':0,'timeout':1000}}
print(json.dumps({'_format_version':'3.0','services':[{'name':'echo','url':'http://echo:5678','routes':[{'name':'echo-route','paths':['/echo'],'strip_path':False,'plugins':[{'name':'rate-limit-advanced','config':cfg}]}]}]}))
")
apply_config "$JSON"; sleep 2
docker compose stop redis
curl -is localhost:8030/echo | head -6
docker compose start redis; sleep 2
curl -is localhost:8030/echo | grep -E "HTTP|X-RateLimit-Status|X-App-Name"   # after recovery
docker compose logs kong1 --since 2m | grep "failing open" | tail -1
```

**Acceptance**:
- [x] While Redis is stopped: HTTP **200** + `X-RateLimit-Status: degraded` + `X-App-Name: http-echo` (request reached upstream)
- [x] After recovery: 200, no degraded header
- [x] Log shows `limiter unavailable, failing open` (warn)

**Result: ✅ PASS**

### Case 7｜Token refill (test D, rate=1 token/s)

```bash
source bench/common.sh
apply_config "$(kong_config_json 60 60 1 true manual-c7)"    # rate = 60/60 = 1/s, burst=60
sleep 2
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code} ' localhost:8030/echo; done; echo
sleep 5
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' localhost:8030/echo; done; echo
docker compose exec redis redis-cli KEYS 'kong:rl:*manual-c7*'
# substitute the key printed above:
docker compose exec redis redis-cli HGETALL 'kong:rl:{manual-c7:p=<fingerprint>:ip=172.20.0.1}'
```

**Acceptance**:
- [x] Exhaustion phase: number of 200s ≈ 60 + elapsed seconds (typing slowly refills a few extra; anything ≤67 counts as correct), followed by continuous 429s
- [x] After waiting 5 seconds: exactly **4–5 200s** (= ⌊elapsed × 1⌋), then back to 429
- [x] Bucket `tokens ≤ 60` (burst cap), `ts` updated

**Result: ✅ PASS** (automated reference value: 5.004s → exactly 5; manual judging accepts 4–5)

### Case 8｜Clock rollback causes no double refill

```bash
source bench/common.sh
apply_config "$(kong_config_json 60 60 1 true manual-c8)"; sleep 2
curl -s -o /dev/null -w '%{http_code}\n' localhost:8030/echo      # create the bucket
KEY=$(docker compose exec redis redis-cli --scan --pattern 'kong:rl:*manual-c8*')
docker compose exec redis redis-cli HGETALL "$KEY"               # tokens=59
FUTURE=$(( $(date +%s) + 3600 ))
docker compose exec redis redis-cli HSET "$KEY" ts "$FUTURE"      # set ts to 1 hour in the future
curl -s -o /dev/null -w '%{http_code}\n' localhost:8030/echo      # one more request
docker compose exec redis redis-cli HGETALL "$KEY"
```

**Acceptance**:
- [x] Second request 200, `tokens` exactly 59→58 (no refill at all)
- [x] `ts` still equals the $FUTURE value — not overwritten with the current time (the old code would overwrite; once the clock caught up, that hour would be refilled twice)

**Result: ✅ PASS**

### Case 9｜Forged X-Forwarded-For does not switch bucket

```bash
./bench/xff.sh
```

**Acceptance**:
- [x] Output `200=1  429=19  total=20` + `PASS: forged XFF produced no new bucket`
- [x] (Optional manual reproduction) under a `limit=1 batch=1` config, send curls with different XFF headers in a burst; only the first is 200

**Result: ✅ PASS**

### Case 10｜namespace round isolation + per-node assertion (built in)

```bash
./bench/quota.sh -l 1000000 -b 1 -p 10
./bench/quota.sh -l 1000000 -b 1 -p 10
docker compose exec redis redis-cli KEYS 'kong:rl:*'
```

**Acceptance**:
- [x] The two rounds' logs have different `namespace=rl-<timestamp>-<pid>`
- [x] KEYS shows two keys with different namespace segments and the **same fingerprint segment** (`p=e891f3c2`)
- [x] Both rounds print `per-node request count assertion passed: kong1/2/3 each 10 requests`

**Result: ✅ PASS**

### Case 11｜Fingerprint properties (all verified in one command)

```bash
docker compose exec kong1 resty -e '
local a = require "kong.plugins.rate-limit-advanced.lib.algorithm"
local function clone(t) local c={} for k,v in pairs(t) do if type(v)=="table" then local d={} for i,x in ipairs(v) do d[i]=x end c[k]=d else c[k]=v end end return c end
local base = {limit=100, window=3600, burst=0, batch=20, limit_by={"ip","path"}, namespace="rl", redis={key_prefix="kong:rl"}}
local fp = a.policy_fingerprint; local b
b=clone(base); b.limit=200;   assert(fp(base)~=fp(b),"limit")
b=clone(base); b.window=60;   assert(fp(base)~=fp(b),"window")
b=clone(base); b.burst=200;   assert(fp(base)~=fp(b),"burst")
b=clone(base); b.limit_by={"path","ip"}; assert(fp(base)~=fp(b),"order")
b=clone(base); b.limit_by={"ip","path","header"}; b.header_name="X-Api"; assert(fp(base)~=fp(b),"header dim")
b=clone(base); b.batch=5;     assert(fp(base)==fp(b),"batch must not change")
b=clone(base); b.burst=100;   assert(fp(base)==fp(b),"burst 0 == limit")
local h1=clone(base); h1.limit_by={"header"}; h1.header_name="X-A"
local h2=clone(base); h2.limit_by={"header"}; h2.header_name="X-B"
assert(fp(h1)~=fp(h2),"header_name")
local big=clone(base); big.limit=1000; big.limit_by={"ip"}
assert(#fp(big)==8 and fp(big):match("^[0-9a-f]+$"),"8 hex")
assert(#fp(base)==8 and fp(base):match("^[0-9a-f]+$"),"8 hex")
print("FINGERPRINT_PROPS_OK base="..fp(base).." limit1000="..fp(big))
'
```

**Acceptance**: the last line prints `FINGERPRINT_PROPS_OK base=25c15179 limit1000=8039753e` (all 10 assertions pass, no assert errors)

**Result: ✅ PASS**

---

## 4. Troubleshooting Quick Reference

| What to check | Command |
|---|---|
| Container status | `docker compose ps` |
| Admin plane of the three nodes | `for p in 8031 8011 8021; do curl -s -o /dev/null -w "%{http_code} " localhost:$p/status; done` |
| All buckets | `docker compose exec redis redis-cli KEYS 'kong:rl:*'` |
| State of one bucket (tokens/ts) | `docker compose exec redis redis-cli HGETALL '<key>'` |
| Find the key of a round | `docker compose exec redis redis-cli --scan --pattern 'kong:rl:*<namespace fragment>*'` |
| Flush DB (test environment only!) | `docker compose exec redis redis-cli FLUSHDB` |
| Logs of one round (filtered by namespace, cleanest) | `docker compose logs kong1 kong2 kong3 \| grep '<namespace>'` |
| Decision distribution | append to the previous: `\| grep -o 'granted=[0-9]*' \| sort \| uniq -c` |
| Local lease pool hit count | append to the previous: `\| grep -c local_hit` |
| Redis grant count | append to the previous: `\| grep -c redis_grant` |
| fill distribution | append to the previous: `\| grep -o 'fill=[0-9]*' \| sort \| uniq -c` |
| Stack traces (must always be 0) | `docker compose logs kong1 --since 5m \| grep -c traceback` |
| Failure-branch logs | `docker compose logs kong1 --since 5m \| grep -E 'failing (open\|closed)'` |
| Status code tally (after a curl loop) | `\| sort \| uniq -c` |
| Push a config (no hand-written JSON) | `source bench/common.sh; apply_config "$(kong_config_json <limit> <window> <batch> true <ns>)"` |
| Restore the initial kong.yml config | `docker compose restart kong1 kong2 kong3` |
| Config with manually specified fault_tolerant | use the python3 construction from Case 6 |

**Two frequent pitfalls**:
1. When Redis is stopped the logs show `DNS resolution failed` — with the container down the name cannot resolve; this is the real failure shape of "Redis unreachable", not another bug.
2. If the numbers don't match, the first thing to check is the **isolation preamble**: after FLUSHDB under the same policy the old local lease pool is still valid (legal semantics, under-issue direction); not clearing worker lease state pollutes the results.

---

## 5. Expected-Value Anchors (for regression comparison)

| Item | Value |
|---|---|
| Fingerprint limit=100/window=3600/burst→100/limit_by=ip,path | `25c15179` |
| Fingerprint limit=1000/…/limit_by=ip | `8039753e` |
| Fingerprint limit=100/…/limit_by=ip | `50780f62` |
| Fingerprint limit=1000000/…/limit_by=ip | `e891f3c2` |
| Key format | `kong:rl:{<ns>:p=<8-hex>:ip=172.20.0.1}` |
| batch=1 baseline (450 requests) | allowed=100 / limited=350 / other=0 / redis_grant=450 |
| batch=20 baseline (under the isolation protocol) | allowed=100 (range [40,100]) |
| Refill rate (limit=60/60s) | 5.004s → 5 tokens |
| Failure log anchors | `algorithm.lua:136 grant failed` → `handler.lua:29 failing open` / `handler.lua:34 failing closed` |

---

## 6. Commit Chain (one commit per group, rollback at group granularity)

```
0ef735a docs: manual test record test/first-commit.md (this document)
41b10f9 group 8: Phase 1 integration acceptance (tests A-D + report)
5b33762 group 7: IP dimension regression test (bench/xff.sh)
912eab2 group 6: load-test script consolidation (namespace isolation + per-node assertion)
4dd3576 group 5: Fail-Closed default (schema + kong.yml + docs)
f830672 group 4: policy fingerprint in keys (FNV-1a + dual-bucket isolation measured)
04cad54 group 3: main decision flow fixes (nil handling / batch=1 short-circuit / get_ip)
f081647 group 2: Redis Lua timestamp monotonicity (dual-source sync)
352b7fe group 1: rollback baseline and environment self-check
3d06fdf baseline: rollback anchor before the P0 fixes
```

---

## 7. Open Items (input for the next change)

- `rule.md` §3.2/§3.3 key format examples do not yet include the `p=` fingerprint (author's original document, to be synced after the author confirms)
- P1 batch: reset/remaining semantics (Remaining always 0 when batch=1), EVALSHA, Retry-After cap, 429 logging, defensive validation of Redis return values, header_name schema validation, shared dict degraded-mode warning
- Phase 4: batch×RPS matrix, non-uniform traffic backlog, local lease pool rental lifecycle (must guard against double returns), `bench/out` permission precheck
- Phase 5: Prometheus metrics, structured logs, long-run/node-restart scenarios

**Manual acceptance: PASSED (this document is the acceptance record and the reproducible playbook).**


> **Historical note (added in Phase 8.2-C)**: this playbook is a Phase 1 historical record. At the time RL-DEBUG logs were at notice level
> (the local_fill/redis_grant counts could be grepped directly); the request hot path RL-DEBUG has since been downgraded to debug level in Phase 8.2-B —
> to collect the corresponding debug logs, run with `KONG_LOG_LEVEL=debug` (Kong's default notice level does not emit them).
> Historical steps and conclusions are preserved as-is.
