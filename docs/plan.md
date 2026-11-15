# 4-Day Implementation Roadmap (every step has a runnable artifact)

> Principle: **something that never ran is not something learned**. Each day must end with
> an artifact you can `curl` a result out of. Total budget 4 days with a half-day buffer.
> If only 2 days remain, cut the Day 3 matrix and keep only the `batch=1` vs `batch=20`
> two-point comparison.

---

## Day 0 (half day): The Kong Plugin Mechanism —— Goal: make a plugin "exist"

**Three things to understand**

1. **A plugin is a directory + two files**: `schema.lua` (config model; Kong uses it to
   validate Admin API input and generate docs) and `handler.lua` (returns a table
   containing `PRIORITY` and per-phase functions). Directory name = plugin name.
2. **Phase order**: `certificate → rewrite → access → response → header_filter →
   body_filter → log`. Rate limiting goes in `access` (intercepted before forwarding
   upstream; the cheapest place).
3. **The PDK is the only entry point**: `kong.request.*` / `kong.response.*` /
   `kong.client.*` / `kong.log.*`. Do not use raw `ngx.*` for business logic in the plugin
   (infrastructure like `ngx.shared` / `ngx.now` is fine).

**Required reading**

- The official Kong *Plugin Development Guide* (`docs.konghq.com/gateway/latest/plugin-development/`)
- **The Kong source under `kong/plugins/rate-limiting/`**, including `schema.lua`,
  `handler.lua`, `policies/` —— this is the highest-value step: the official
  implementation is your comparison group, and you will see it is exactly "fixed window +
  one Redis call per request".

**Same-day artifact (Gate 1)**

```bash
docker compose up -d
curl -i http://localhost:8030/echo     # response headers contain X-RateLimit-* (values may all be fake at this point)
```

Being able to change `limit` in `kong.yml`, and after `POST /config` seeing the response
header numbers change, counts as passing.

**Pitfalls**

- The plugin directory must be mounted to the container path
  `/usr/local/share/lua/5.1/kong/plugins/<name>`, with `KONG_PLUGINS=bundled,<name>`.
- Renaming without syncing: the `name` in `schema.lua` must match the directory name,
  otherwise the plugin silently fails to load.
- In DB-less mode the Admin API is essentially read-only; config changes go through
  `POST /config` or `kong reload`.

---

## Day 1 (1 day): Redis + Lua Atomic Rate Limiting —— Goal: 100% correct single-node semantics

**Three things to understand**

1. **Redis single thread + script atomicity**: no other commands interleave during an
   `EVAL` execution, so "read-compute-write" is naturally a transaction; no
   WATCH/MULTI needed. This is the fundamental reason rate limiting can live in Redis.
2. **Time must come from `redis.call('TIME')`**, not from the Kong node's `ngx.now()`.
   With 1 second of cross-machine clock drift, the token bucket over- or under-counts an
   entire second's worth. This is the pitfall beginners hit most often.
3. **Return-value type traps**: Redis truncates Lua numbers to integers when returning;
   floats (e.g. remaining tokens 99.37) must be `tostring()`ed before returning,
   otherwise you always see 99.

**Required reading**

- The Redis `EVAL` documentation (script atomicity, `redis.call` vs `redis.pcall`)
- `lua-resty-redis` (`connect` / `set_timeouts` / `set_keepalive`; **forgetting keepalive
  exhausts ports under high concurrency**)

**Same-day artifact (Gate 2)**

```bash
# First, outside Kong, run the script bare in redis-cli
redis-cli --eval redis/token_bucket.lua rl:test , 1.67 100 1 120000
```

Execute it 101 times in a row: the first 100 return `{1,...}`, the 101st returns `{0,...}`,
and the wait in the third argument is positive.

**Pitfalls**

- `HMGET` returns `false` (not `nil`) for nonexistent fields, and `tonumber(false)` is
  `nil` — don't write `if d[1] == nil`.
- `PEXPIRE` uses milliseconds and `EXPIRE` uses seconds; mixing them makes keys expire
  instantly or never.
- Do not use `math.random` in scripts (nondeterministic results; replication diverges).

---

## Day 1.5 (half day): Wiring into Kong —— Goal: correct single-node 429

Hook up `algorithm.lua` and run `batch=1` only (drawing 1 token from Redis each time).

**Same-day artifact (Gate 3)**

```bash
# limit=5, window=60
for i in $(seq 1 7); do curl -s -o /dev/null -w "%{http_code} " localhost:8030/echo; done
# Expected: 200 200 200 200 200 429 429
```

And the 6th response carries `Retry-After`, of magnitude ≈ 60/5 = 12 seconds.

---

## Day 2 (1 day): Going Distributed —— Goal: prove "three nodes, one pool"

**Order matters**: 1 node → start the 2nd → start the 3rd. At each step, first confirm
"the quota is shared" before moving on.

**Same-day artifact (Gate 4)**

`limit=100, window=3600, batch=1`, 150 requests per node (450 total):

```
Total pass count == 100 (strictly equal)
```

Then set `batch` to 20 and rerun:

```
Total pass count ∈ [40, 100]      # under-admission, never over-admission
```

**This step is the core thesis of the entire take-home assignment**: the same code, one
parameter, sliding from "exact" to "fast".

**Pitfalls**

- The three Kong containers each have their own declarative config; config changes must
  `POST /config` to **all three** nodes; hitting only one produces the bizarre phenomenon
  of "inconsistent config across nodes".
- Don't use an external load balancer; client round-robining over three ports is the most
  intuitive; once an LB is in the path you can no longer say which node a request landed on.

---

## Day 2.5 (half day): Performance Matrix —— Goal: one table with conclusions

**Experiments must control variables**: change only `batch`, fix everything else; at
least 30s per group; run the baseline first (no plugin).

**Same-day artifact (Gate 5)**

`bench/results.md` contains three curves (or one table):

| batch | p99 | Pass count | Redis ops/s |
|---|---|---|---|
| Baseline (no plugin) | ? | All pass | 0 |
| 1 | ? | 100 | ~RPS |
| 20 | ? | ~95 | RPS/20 |

**The conclusion must be written as one sentence**, e.g.:
> "At batch=20, p99 is only 0.2ms above the baseline, Redis load drops to 1/20, and the
> cost is at most 6% of quota under-admitted. At small quotas (limit<100) this cost is
> unacceptable, so auto degrades to batch=1."

---

## Day 3 (1 day): Documentation —— Goal: let the interviewer understand your trade-offs in 10 minutes

Fill in following the skeleton of `docs/design.md`; the point is not the feature list but:

1. **Architecture diagram** (bonus, must have)
2. **Error upper-bound derivation** (proving you know your solution's boundary, not just
   that "it ran")
3. **Trade-off table**: what was done / what was simplified / why
4. **Productionization gap list**: what is still missing to go live
5. **Comparison with the official plugin**: shows you are not reinventing the wheel but
   know where the wheel falls short

---

## Trim Order When Time Runs Short

When cutting to 2 days, drop in this order:

1. Drop the full matrix in `docs/bench.md` → keep only `batch=1` vs `batch=20`
2. Drop the multi-dimensional combinations of `limit_by` → keep only `ip`
3. Drop failure degradation (fail-open) → but **never drop** the error analysis; that is
   the most valuable part of the whole piece
