# Manual Test Playbook — Phase 2 Multi-Dimension Semantics and Observability Baseline (phase2-manual)

**Date**: 2026-11-11
**Status**: ✅ executed (2026-11-11, manual 10/10 all passed)
**Corresponding change**: `openspec/changes/phase2-dimensions-and-semantics` (20/20 tasks completed, automated acceptance in `reports/phase-2-dimensions-and-semantics.md`)
**Companion**: Phase 1 manual record in `test/first-commit.md`

> Rules are the same as Phase 1: **run the isolation preamble before every Case**; execute in bash (zsh is incompatible with the arrays in `bench/common.sh`); if docker reports permission denied, run `newgrp docker` first.
> Each Case's "purpose" states which design decision (D1–D9, see the change's design.md) or which review finding (P1 numbering) of review-phase-0 it corresponds to — tests and trade-offs are mutually traceable.

---

## 0. Preparation and Isolation Preamble

```bash
cd /home/tdohs/kong/kong-ratelimit
docker compose ps                 # expect 5 containers running/healthy

# Isolation preamble (run at the start of every Case):
docker compose restart kong1 kong2 kong3
sleep 20 && curl -s -o /dev/null -w 'ready: %{http_code}\n' localhost:8031/status   # expect 200
docker compose exec redis redis-cli FLUSHDB    # expect OK
```

---

## Case A｜429 same-basis values (Reset−now == Retry-After)

**Purpose**: verifies D1 (Reset = when the next token becomes available). Corresponds to review findings P1-2 + P1-9: the old implementation's `Reset = now + window` was pseudo-window semantics — the client got two self-contradictory numbers at once, `Reset−now=3600` and `Retry-After=36`. `limit=100/window=3600` is chosen to produce a wait value that is easy to eyeball (rate=0.0278/s ⇒ wait≈36s): if the implementation still had the old semantics, the 3600≠36 mismatch gives it away instantly; if the handler forgot to derive Reset from the capped Retry-After, this goes red too.

```bash
source bench/common.sh
apply_config "$(kong_config_json 100 3600 1 true manual-p2a)"; sleep 2
docker compose exec redis redis-cli FLUSHDB
for i in $(seq 1 100); do curl -s -o /dev/null localhost:8030/echo; done
NOW=$(date +%s)
curl -is localhost:8030/echo | tr -d '\r' | grep -iE 'HTTP/|Retry-After|X-RateLimit-Reset'
echo "now=$NOW"
```

**Acceptance**:
- [ ] HTTP 429
- [ ] `Retry-After` = 36±1 (rate=100/3600)
- [ ] `X-RateLimit-Reset − now` == Retry-After (±1 second) — same basis (under the old semantics Reset would be now+3600)

Result: ✅ PASS

## Case B｜Retry-After cap

**Purpose**: verifies the boundary behavior of D2. `limit=1/window=3600` is an **extremely small rate**: wait=(1−0)/0.001=3600, sitting exactly on the cap boundary — the only config that can verify both "the cap takes effect" and "the cap does not over-correct" at once (under a normal config wait is mathematically ≤ window/limit ≤ window, so the cap is redundant insurance; this case pins down that "the insurance is indeed harmless"). If the cap is coded wrong (min/max swapped, wrong window field), anomalous values show up here.

```bash
apply_config "$(kong_config_json 1 3600 1 true manual-p2b)"; sleep 2
docker compose exec redis redis-cli FLUSHDB
curl -s -o /dev/null localhost:8030/echo
curl -is localhost:8030/echo | tr -d '\r' | grep -iE 'HTTP/|Retry-After'
```

**Acceptance**:
- [ ] 429 with `Retry-After: 3600` (= the window cap, and never larger)

Result: ✅ PASS

## Case C｜Fast/slow path Reset = "next token already available"

**Purpose**: the easiest place for D1 to break — the Reset on the two paths has **different sources** (fast path = local approximation, slow path = Redis wait), and basis drift is a classic bug. `batch=20` creates a fast path (the 2nd request draws from the local lease pool), and `1000/60` makes the rate large enough that wait=0. Sequence design: the 1st request must find the pool empty (slow path), the 2nd must hit (fast path) — both should get Reset≈now. If the fast path was missed (still returning now+window) or the slow path returns the old reset_at, it shows up immediately; `Remaining 19→18` incidentally confirms the lease semantics were not broken.

```bash
apply_config "$(kong_config_json 1000 60 20 true manual-p2c)"; sleep 2
docker compose exec redis redis-cli FLUSHDB
date +%s
curl -is localhost:8030/echo | tr -d '\r' | grep -i 'X-RateLimit-'
curl -is localhost:8030/echo | tr -d '\r' | grep -i 'X-RateLimit-'
```

**Acceptance**:
- [ ] 1st request (slow path): `Remaining: 19`
- [ ] 2nd request (fast path): `Remaining: 18`
- [ ] Both requests' `X-RateLimit-Reset` ≈ the `date +%s` printed above (lease available ⇒ next token already available; no longer the old now+60 semantics)

Result: ✅ PASS

## Case D｜header_name upfront validation (400 at push time)

**Purpose**: verifies D4 (review finding P1-4). A bad config used to be accepted at push time and only blow up as a 500 at runtime — the error surfaced on production traffic; entity_checks moves validation up front to the Admin API. **Pushing only the bad config is not enough**: the most common failure of a validator is "rejecting valid configs" (contains not applying to arrays → always reject / always pass), so controls are required (201 for a config with header_name, 201 for the existing [ip]). The 400 error body must also show field attribution (`config.header_name: required field missing`) — proving the trigger was this rule and not some other validation.

```bash
python3 -c "
import json
cfg={'limit':100,'window':3600,'batch':1,'limit_by':['header'],'namespace':'manual-p2d-bad','redis':{'host':'redis','port':6379,'database':0,'timeout':1000}}
print(json.dumps({'_format_version':'3.0','services':[{'name':'echo','url':'http://echo:5678','routes':[{'name':'echo-route','paths':['/echo'],'strip_path':False,'plugins':[{'name':'rate-limit-advanced','config':cfg}]}]}]}))
" > /tmp/bad.json
curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8031/config -H 'Content-Type: application/json' -d @/tmp/bad.json
```

**Acceptance**:
- [ ] HTTP **400**, error body contains `header_name` and `required field missing`
- [ ] (Control) change `"limit_by":["header"]` into a config that also carries `"header_name":"X-Tenant"` and POST again → 201

Result: ✅ PASS

## Case E｜429 decision log

**Purpose**: verifies D8 (review finding P1-7). If 429 (deterministic rejection) and 503/degraded (failure) are not distinguished in logs, triage cannot tell whether a high rejection rate is the policy working or fallout from a failure. Hidden assertion: **the log level must be notice** — under `KONG_LOG_LEVEL=notice` nginx does not emit info-level logs, so if the implementation used `log.info`, this grep would show nothing. Wrong level, wrong branch, or missing fields (key/limit/batch) cannot escape.

```bash
docker compose logs kong1 --since 10m | grep '429 key=' | tail -3
```

**Acceptance**:
- [ ] Log line like `rate-limit-advanced: 429 key=<rate-limit key> limit=100 batch=1`
- [ ] This log is instantly distinguishable from the failure logs (`failing closed/open`)

Result: ✅ PASS

## Case F｜Redis defensive validation unit test

**Purpose**: verifies D3. When Redis returns malformed data, the old implementation's `tonumber(x) or 0` would silently treat granted as 0 (wrong 429) or accept malformed data as valid (wrong pass-through) — when the data cannot be trusted, no deterministic decision should be made. **Why a unit test and not E2E**: there is no way to make a real Redis emit malformed data (the script is our own), and injection would require a fake Redis server — high cost, low benefit; the validation function is pure, so a unit test can feed it every malformed shape — "the test method matches the thing under test". Each sample covers one class of defensive gap: non-table / wrong length / non-numeric / out of range (>want, <0, fractional) / wait<0.

```bash
docker compose exec kong1 resty -e '
local rm = require "kong.plugins.rate-limit-advanced.lib.redis"
local p = rm.parse_grant_response
assert(select(1, p("x", 20)) == nil)
assert(select(1, p({1,2}, 20)) == nil)
assert(select(1, p({21,"1","1"}, 20)) == nil)   -- granted>want
assert(select(1, p({"1","y","1"}, 20)) == nil)  -- tokens not a number
assert(select(1, p({"1","1",-2}, 20)) == nil)   -- wait<0
local ok = p({20,"99.5","0"}, 20)
assert(ok and ok.granted == 20)
print("PARSE_GRANT_OK")
'
```

**Acceptance**: prints `PARSE_GRANT_OK` (all malformed rejected, valid passes)

Result: ✅ PASS

## Case G｜shared dict degraded-mode warning (normal startup should be silent)

**Purpose**: verifies the negative side of D5 (review finding P1-8). Degrading to a worker-private table is intentional design (it can run without a shared dict), but it used to be completely silent — operations could not tell that precision had dropped from "node level" to "worker level". This case tests for **0 warnings in a normal environment**: warning noise makes people ignore real problems. The positive case (actually starting a temporary container without a shared dict) is already covered by the automated acceptance (report §7-16); the manual run skips it because the cost of a `docker run` throwaway container is out of proportion.

```bash
docker compose logs kong1 kong2 kong3 --since 30m | grep -c degraded    # expect 0
```

**Acceptance**:
- [ ] 0 lines (the degraded warning only appears at startup when the shared dict is missing; for the positive-case verification method see `reports/phase-2-dimensions-and-semantics.md` §7-16)

Result: ✅ PASS

## Case H｜consumer dimension (key-auth + three identities independent)

**Purpose**: verifies the consumer scenario of D6/D7 (empirical proof of the MVP "Client ID granularity"). This is the **only dimension that depends on "another plugin running first"**: if key-auth (1250) does not run before rate limiting (1002), `get_consumer()` gets no identity and everything falls into anon — direct evidence that the PRIORITY design is correct. The `anonymous` field in the config is key: the rate-limit plugin never sees requests that "failed authentication" (key-auth would 401 them first); to let unauthenticated requests reach the limiter and land in the anon bucket, key-auth's anonymous consumer mechanism must be used to let keyless requests through. Sequence alice→bob→anon, each 200/429: if the consumer value is wrong (same id) you would see 200,429,429…; if anon shared a bucket with alice, the order would scramble. `attempt to call=0` rules out PDK error interference.

```bash
NS=manual-p2h
python3 -c "
import json, sys
anon='33333333-3333-3333-3333-333333333333'
rl={'limit':1,'window':3600,'batch':1,'limit_by':['consumer'],'namespace':sys.argv[1],'redis':{'host':'redis','port':6379,'database':0,'timeout':1000}}
print(json.dumps({'_format_version':'3.0','consumers':[
 {'username':'alice','id':'11111111-1111-1111-1111-111111111111','keyauth_credentials':[{'key':'alice-key'}]},
 {'username':'bob','id':'22222222-2222-2222-2222-222222222222','keyauth_credentials':[{'key':'bob-key'}]},
 {'username':'anon-visitor','id':anon}],
 'services':[{'name':'echo','url':'http://echo:5678','routes':[{'name':'echo-auth','paths':['/auth'],'strip_path':False,
  'plugins':[{'name':'key-auth','config':{'anonymous':anon}},{'name':'rate-limit-advanced','config':rl}]}]}]}))
" "$NS" > /tmp/consumer.json
docker compose exec redis redis-cli FLUSHDB
curl -s -o /dev/null -w 'config: %{http_code}\n' -X POST localhost:8031/config -H 'Content-Type: application/json' -d @/tmp/consumer.json   # expect 201

for r in 1 2; do curl -s -o /dev/null -w "alice-$r: %{http_code}\n" localhost:8030/auth -H 'apikey: alice-key'; done
for r in 1 2; do curl -s -o /dev/null -w "bob-$r: %{http_code}\n"   localhost:8030/auth -H 'apikey: bob-key';   done
for r in 1 2; do curl -s -o /dev/null -w "anon-$r: %{http_code}\n"  localhost:8030/auth; done
docker compose logs kong1 --since 5m | grep -c 'attempt to call'
```

**Acceptance**:
- [ ] `config: 201`
- [ ] Sequence alice=200/429, bob=200/429, anon=200/429 (the three identities' quotas fully independent)
- [ ] `attempt to call` count = 0 (empirical proof that key-auth 1250 runs before rate limiting 1002)

Result: ✅ PASS

## Case I｜route / service dimensions in the key

**Purpose**: verifies the route/service dimensions (spec ADDED). The value is a UUID — if `dim_value` returned "-" (no match) or the key lacked that segment, rate limiting by route would **silently degrade into one site-wide bucket**. The kill shot here is not the 200/429 counts but **inspecting the key contents directly**: only `route=<uuid>` appearing inside the hash tag is conclusive proof. `limit=1` is enough (one 200 then one 429); the point is the key shape; using `--scan` is production habit (`KEYS` blocks Redis).

```bash
source bench/common.sh
apply_config "$(kong_config_json 1 3600 1 true manual-p2i '["route"]')"
docker compose exec redis redis-cli FLUSHDB
curl -s -o /dev/null localhost:8030/echo
docker compose exec redis redis-cli --scan --pattern 'kong:rl:*manual-p2i*'
# service dimension: replace both '["route"]' occurrences with '["service"]', change the namespace to manual-p2j, and run again
```

**Acceptance**:
- [ ] Key looks like `kong:rl:{manual-p2i:p=<8-hex fingerprint>:route=<uuid>}`
- [ ] Service-version key looks like `…:service=<uuid>`

Result: ✅ PASS

## Case J｜One-command full run (final-state recheck)

**Purpose**: Cases A–I above are manual sampling; dims.sh is a regression **hardened into assertions**: 7 scenarios anyone can re-test with one command. The relationship between manual testing and automated regression is "manual testing confirms the experience and the edges; scripts guarantee repeatability" — after finishing this playbook, every future code change needs only `dims.sh` + `quota.sh` as the regression floor for multi-dimension + quota.

```bash
./bench/dims.sh
```

**Acceptance**:
- [ ] `PASS=8 FAIL=0`, printing `all dimension scenarios passed`

Result: ✅ PASS

---

## Wrap-up

```bash
docker compose restart kong1 kong2 kong3    # restore the initial kong.yml config (the POSTs in Case D/H overwrote the runtime config)
```

## Result Summary (2026-11-11 manual run: 10/10 passed)

| Case | Content | Result |
|---|---|---|
| A | 429 same-basis values | ✅ |
| B | Retry-After cap | ✅ |
| C | Fast/slow path Reset | ✅ |
| D | header_name 400 at push time | ✅ |
| E | 429 decision log | ✅ |
| F | Defensive validation unit test | ✅ |
| G | Degraded warning silent | ✅ |
| H | Consumer three identities independent | ✅ |
| I | route/service in key | ✅ |
| J | dims.sh one-command full run | ✅ |


> **Historical note (added in Phase 8.2-C)**: this playbook is a Phase 2 historical record. At the time RL-DEBUG logs were at notice level
> (the local_fill/redis_grant counts could be grepped directly); the request hot path RL-DEBUG has since been downgraded to debug level in Phase 8.2-B —
> to collect the corresponding debug logs, run with `KONG_LOG_LEVEL=debug` (Kong's default notice level does not emit them).
> Historical steps and conclusions are preserved as-is.
