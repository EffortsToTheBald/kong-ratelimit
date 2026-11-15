# Kong Advanced Rate Limiting
# SDD Development Specification and Phased Optimization Implementation Document

**Project name:** rate-limit-advanced  
**Document type:** Software Design Specification / SDD  
**Goal:** Based on the existing Kong custom rate-limiting plugin, progressively improve the distributed token bucket, global quota consistency, multi-dimension rate-limiting keys, local batch token leasing, and performance optimization.  
**Development approach:** AI-assisted development with phased modification, testing, and acceptance.  
**Core principle:** Preserve the existing architecture; fix correctness issues first, then optimize performance.

---

# 1. Project Background and Goals

## 1.1 Project background

Develop a custom rate-limiting plugin `rate-limit-advanced` based on the open-source Kong Gateway.

Problems the project needs to solve:

1. How multiple Kong nodes share the same global rate-limiting quota.
2. How to guarantee the atomicity of token deduction under concurrent requests.
3. How to support rate limiting across multiple dimensions: IP, Consumer, Path, Method, Header, Route, Service, etc.
4. How to reduce the per-request Redis access overhead.
5. How to improve throughput via a local token inventory while guaranteeing global rate-limiting correctness.
6. How to guarantee rate-limiting safety when Redis is unavailable.
7. How to verify quota correctness and performance in multi-node deployments.

## 1.2 First-version target architecture

Adopt:

- 3 Kong Gateway nodes.
- 1 Redis instance.
- Redis Lua implementing a globally atomic token bucket.
- Kong nodes using `lua_shared_dict` to hold local token inventory.
- A batch mechanism to draw tokens from Redis in bulk.
- The plugin completes the rate-limiting decision during the Kong access phase.

Overall architecture:

```text
                  Client
                    |
                    v
              Load Balancer
                    |
          +---------+---------+
          |         |         |
          v         v         v
       Kong1     Kong2     Kong3
          |         |         |
          |         |         |
          v         v         v
       Shared    Shared    Shared
       Dict      Dict      Dict
          |         |         |
          +---------+---------+
                    |
             Redis Lua Script
                    |
                    v
             Global Token Bucket
```

Notes:

- Each Kong node owns its own `lua_shared_dict`.
- The Nginx workers within the same Kong node share that node's shared dict.
- Different Kong nodes do not share local inventory.
- Redis is the sole authoritative source of the global quota.
- Local inventory is only the token lease credit Redis has already granted to a node.

**Important: the shared dicts of the three Kong nodes are not the same data.**

---

# 2. Core Rate-Limiting Algorithm: Token Bucket

## 2.1 Why the token bucket

The token bucket can simultaneously support:

- Average rate limiting.
- Short-term burst traffic.
- Distributed concurrent deduction.
- Local bulk token drawing.

Compared with a simple fixed-window counter, the token bucket controls the request rate more smoothly.

## 2.2 Core parameters

Configuration:

```json
{
  "limit": 100,
  "window": 3600,
  "burst": 100,
  "batch": 20
}
```

Parameter meanings:

| Parameter | Meaning |
|---|---|
| limit | The token bucket's base quota |
| window | The token refill period, in seconds |
| burst | The token bucket's maximum capacity |
| batch | The number of tokens each Kong node draws from Redis at a time |

Note:

`window` is not the window boundary of a fixed-window counter.

The current scheme is a token bucket model:

```text
rate = limit / window
```

For example:

```text
limit = 100
window = 3600

rate = 100 / 3600
     = 0.02778 tokens/s
```

meaning roughly 0.02778 tokens are refilled per second.

That is, on average 100 tokens are refilled per hour.

If:

```text
burst = 100
```

then the token bucket's maximum capacity is 100.

On the first access after the system starts, the bucket is initialized full.

Therefore:

- Initially up to 100 requests are admitted.
- Tokens are refilled gradually at rate afterwards.
- The token count can never exceed burst.

This is a continuously refilling token bucket, not a reset-to-100 at each hour boundary.

## 2.3 Token bucket formulas

Assume:

- `tokens`: the token count remaining from the last computation.
- `now`: the current Redis time.
- `ts`: the timestamp of the last computation.
- `rate`: tokens refilled per second.
- `burst`: bucket capacity.

Refilling tokens:

```text
elapsed = now - ts

tokens = min(
    burst,
    tokens + elapsed * rate
)
```

Consuming tokens:

```text
if tokens >= want:
    granted = want
else:
    granted = floor(tokens)

tokens = tokens - granted
```

Note: the current implementation allows partial grants.

For example:

```text
want = 20
tokens = 13.8

granted = 13
```

Computing the wait time:

```text
if tokens < 1:
    wait = (1 - tokens) / rate
```

Redis Lua must guarantee:

1. Reading the token count.
2. Computing the refill.
3. Deducting tokens.
4. Updating the state.
5. Updating the TTL.

All of the above execute atomically within a single Lua script.

## 2.4 Redis time

Use:

```lua
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
```

Do not use the Kong node's local clock as the basis for global bucket computation.

Reason:

Multiple Kong nodes may have clock skew.

Having Redis provide a unified time avoids time drift caused by different gateway nodes computing refills independently.

Additionally, clock rollback must be checked:

```text
if now > ts:
    refill tokens
else:
    do not refill tokens
```

Extra tokens must not be generated due to clock rollback.

---

# 3. Redis Key Design

This is an important design of the project; the existing conventions must be preserved.

## 3.1 Key format

Adopt:

```text
kong:rl:{rl:p=25c15179:ip=10.0.0.7:path=/echo}
```

Structure:

```text
kong:rl:
    {
        rl:
        p=25c15179:
        ip=10.0.0.7:
        path=/echo
    }
```

Where:

- `kong:rl:` is the Redis key prefix.
- `{}` is the Redis Cluster hash tag.
- `rl:` is the rate-limiting rule namespace.
- `p=25c15179` is the policy fingerprint (8 hex digits, FNV-1a 32-bit; input = limit, window, the parsed burst, the limit_by order, and header_name (for the header dimension only)).
- `ip=...` is the IP dimension.
- `path=...` is the Path dimension.

**Semantics of the policy fingerprint (added in Phase 2)**:

- Any policy parameter change immediately yields a new key ⇒ a new bucket; the old bucket and its old local inventory are naturally phased out by TTL (the measured pre-fix over-admission of 116 > 100 stems from this).
- The fingerprint **excludes batch**: batch is a transport parameter and does not constitute bucket identity; changing batch does not clear the quota.
- Cost: changing limit/window/burst/limit_by instantly "refills" the quota to full; when the intent is "change limit but inherit the remaining balance", use `namespace` to control it explicitly (unchanged namespace ⇒ unchanged bucket).

**Multi-rule group keys (Phase 3 · α decision)**:

Multi-rule mode (the `rules` array) uses **group keys**, with all rule buckets sharing the same hash tag:

```text
kong:rl:{rl:g=3acf5710:r1:consumer=anon}
kong:rl:{rl:g=3acf5710:r2:consumer=anon:path=/echo}
```

- `g=<8-digit group fingerprint>`: group fingerprint = FNV-1a over all rules' limit/window/burst/limit_by/header_name concatenated in order.
  **Any rule parameter change ⇒ the whole group gets new keys** (changing one rule = a full group quota reset; this cost must be documented).
- `r<i>`: the rule's ordinal segment within the rules array (1-based).
- The group shares one hash tag ⇒ one Redis Cluster slot ⇒ multi-key EVAL is usable (a hard prerequisite for Cluster deployment,
  and the forward fulfillment of the original single-rule hash tag design).
- α strong-consistency semantics: when `rules` is non-empty there is **no local inventory and no batch lease**; each request runs one multi-key atomic Lua
  — if every bucket has ≥1 ⇒ each deducts 1; if any bucket falls short ⇒ none deduct and the deficient rule is returned (strongly consistent;
  the check and deduction are indivisible inside the single-threaded Redis script, with no local rollback window).
- Configuration constraints (violating at issuance is a 400): `rules` and `limit_by` are mutually exclusive; `batch` ∈ {0,1}; rule count ≤ 8.

## 3.2 Why the hash tag

Redis Cluster computes CRC16 from the key and maps it to one of 16384 hash slots.

Redis Cluster supports hash tags:

```text
prefix:{hash-tag}:suffix
```

Only the content inside `{}` is used for slot computation.

For example:

```text
kong:rl:{rl:p=25c15179:ip=10.0.0.7:path=/echo}
kong:rl:{rl:p=25c15179:ip=10.0.0.7:path=/echo}:metadata
kong:rl:{rl:p=25c15179:ip=10.0.0.7:path=/echo}:stats
```

These keys land on the same slot.

This reserves capability for future extension with multiple related Redis keys, Lua multi-key operations, and related state.

**Important constraints:**

1. The complete rate-limiting rule identity must be placed inside the hash tag.
2. The same rule with the same dimension values must generate the same key.
3. Different rules must not accidentally share a bucket.
4. Multiple dimensions must jointly participate in key computation.
5. The dimension order must be stable, to avoid the same logical rule generating different keys.
6. Do not split different dimensions into separate independent keys unless a joint multi-rule decision is explicitly implemented later.
   (Implemented in Phase 3: multi-rule uses group keys — all rule buckets in a group share one hash tag, see the end of §3.1.)

## 3.3 Supported dimensions

| Dimension | Value |
|---|---|
| consumer | Consumer ID |
| ip | Forwarded IP / Remote IP |
| path | Request path |
| method | HTTP method |
| header | Specified header |
| route | Route ID |
| service | Service ID |

For example:

Configuration:

```json
{
  "limit_by": ["ip", "path"]
}
```

Request:

```text
GET /echo
IP = 10.0.0.7
```

Generates:

```text
kong:rl:{rl:p=25c15179:ip=10.0.0.7:path=/echo}
```

If only the following is configured:

```json
{
  "limit_by": ["ip"]
}
```

Generates:

```text
kong:rl:{rl:p=<same policy fingerprint>:ip=10.0.0.7}
```

## 3.4 Key design aspects requiring optimization

Check status (updated in Phase 2):

- [Resolved] Policy identity isolation: the key already contains the `p=` policy fingerprint (limit/window/parsed burst/limit_by order/header_name); a config change means a new bucket; dimension order participates in the fingerprint ([ip,path] ≠ [path,ip], measured fingerprints differ).
- [Resolved] Header length limit: truncate to 256.
- [Resolved] Upfront validation: limit_by includes header but header_name is missing ⇒ 400 at issuance (entity_checks).
- [To do] Special-character escaping and concatenation ambiguity: currently concatenated in `dim=val` order; `val` is not escaped (ambiguous values can in theory be constructed).
- [To do] Rule ID independent identity / namespace distinguishing multiple policies: namespace can distinguish them (an escape hatch); rule-level IDs are not implemented.
- [To do] Path normalization (cardinality governance).

Note: the fingerprint landed with Phase 1/2 and is locked by unit tests (fingerprint property assertions + dims scenario 7).

---

# 4. Distributed Token Management Architecture

## 4.1 Redis global bucket

Redis holds the global state:

```text
Key:
kong:rl:{rl:p=25c15179:ip=10.0.0.7:path=/echo}

Hash:
tokens
ts
```

Example:

```text
tokens = 60
ts = 1794380834.8841
```

Redis is responsible for:

- The global token count.
- Token refill.
- Atomic deduction.
- Bulk token grants.
- Wait-time computation.

Redis is the sole authoritative state.

## 4.2 Kong local inventory

Each Kong node has its own local inventory.

For example:

```text
Kong1:
    local_tokens = 20

Kong2:
    local_tokens = 20

Kong3:
    local_tokens = 20
```

In practice, the inventory is managed by each node's own `lua_shared_dict`.

Local inventory exists to reduce Redis network requests.

Request flow:

```text
Request
   |
   v
store.take(key)
   |
   +---- local tokens available
   |          |
   |          v
   |       deduct 1
   |          |
   |          v
   |       admit request
   |
   +---- no local tokens
              |
              v
        Redis Lua request
              |
              v
        receive granted
              |
              +---- granted = 0
              |          |
              |          v
              |         429
              |
              +---- granted > 0
                         |
                         v
                 current request consumes 1
                         |
                         v
                 remaining tokens placed locally
                         |
                         v
                       admit
```

## 4.3 The batch mechanism

batch denotes how many tokens are requested from Redis at a time.

For example:

```text
batch = 20
```

When the local inventory is empty, 20 tokens are requested from Redis.

Redis atomically deducts 20 tokens.

The current request uses 1 of them.

The remaining 19 are stored into the local inventory.

The next request can use the local inventory directly.

Therefore:

```text
batch = 1
```

Every request needs to request tokens from Redis.

```text
batch = 20
```

After a node's successful request, it can keep serving subsequent requests from local inventory.

## 4.4 The difference between batch=1 and batch=N

| Mode | Characteristics | Cost |
|---|---|---|
| batch=1 | Every request goes through a Redis atomic decision | Larger Redis request volume |
| batch=N | A batch of tokens reserved locally | Tokens may be stranded |

batch=1 is the globally strict quota mode.

batch=N is the distributed token leasing mode.

It must be made explicit:

**batch=N does not mean each node independently gains N units of extra quota.**

The tokens requested by all nodes are still controlled by the same Redis global bucket.

## 4.5 The local token stranding problem

Assume:

```text
limit = 100
batch = 20
Kong nodes = 3
```

If:

```text
Kong1 requests 20
Kong2 requests 20
Kong3 requests 20
```

the three nodes have reserved 60 tokens from Redis.

If Kong1 subsequently receives a large volume of requests while Kong2 and Kong3 receive none, the tokens stranded at Kong2 and Kong3 may never be consumed.

This is token stranding.

It does not cause over-admission, but it lowers quota utilization.

Under ideal conditions, assuming each node strands at most batch−1 tokens:

```text
Theoretical minimum admitted count:

allowed >= limit - N * (batch - 1)
```

To be conservative and compatible with the original test scripts, one can use:

```text
allowed >= max(0, limit - N * batch)
```

where N is the number of Kong nodes.

Note: this range is an engineering acceptance reference based on conditions such as correct local inventory management, exactly one shared inventory pool per node, and no significant token refill during the test; it is not an unconditional mathematical guarantee.

---

# 5. batch Auto-Computation Strategy

Current implementation:

```lua
local k = math.floor(conf.limit / 50)

if k < 1 then
    k = 1
end

if k > 50 then
    k = 50
end

return k
```

Formula:

```text
batch = clamp(floor(limit / 50), 1, 50)
```

Examples:

| limit | auto batch |
|---:|---:|
| 10 | 1 |
| 50 | 1 |
| 100 | 2 |
| 500 | 10 |
| 1000 | 20 |
| 5000 | 50 |

Purpose:

- Small quotas avoid excessive token stranding.
- Large quotas reduce Redis requests.
- The maximum bulk draw is bounded.

Whether this strategy is reasonable needs subsequent verification.

Do not directly modify the default algorithm for now.

Compare via load testing:

- batch=1
- batch=5
- batch=10
- batch=20
- batch=50
- batch=auto

Record quota utilization, Redis request counts, latency, and throughput.

---

# 6. Redis TTL Design

Current algorithm:

```lua
local ttl_s = math.max(
    1,
    math.floor(conf.window * 2)
)

local ttl_ms = ttl_s * 1000
```

For example:

```text
window = 3600

TTL = 7200 seconds
```

i.e., 2 hours.

Purpose:

After a rate-limiting rule has gone without requests for a long time, its Redis state can be cleaned up automatically.

The TTL is not the token refill period.

`window` determines the refill rate.

`TTL` determines how long a Redis key survives without access before expiring.

Items to check:

1. Whether the TTL could expire early while the local inventory is still valid.
2. Whether multiple Kong nodes apply consistent TTLs to the same key.
3. Whether recreating an expired Redis key creates a new full bucket.
4. Whether there is a lifecycle mismatch between the local inventory and the Redis key's expiry.

Particular care:

If a Redis key has expired but the Kong local side still holds tokens leased earlier, the system may exhibit the problem of old inventory coexisting with a new bucket.

A later version needs to address this lifecycle problem through lease validity periods, rule versions, or other mechanisms.

Relying on the Redis TTL alone cannot be treated as the local inventory necessarily expiring in sync.

---

# 7. Failure Policy: Fail-Closed

## 7.1 Why fail-closed

The first version of this project chooses:

**When Redis is unavailable, reject requests with 503.**

Automatic admission during Redis failures is not allowed.

Reason:

If Redis is unavailable and Kong chooses to admit, rate limiting is effectively disabled.

For an API that must guarantee a global quota, this can cause serious loss of traffic control.

## 7.2 Comparison of the two policies

| Policy | When Redis is unavailable | Risk |
|---|---|---|
| Fail-open | Admit requests | May exceed the rate-limiting quota |
| Fail-closed | Return 503 | Reduced business availability |

Current configuration:

```json
{
  "fault_tolerant": false
}
```

Corresponding code:

```lua
if not decision then
    if conf.fault_tolerant then
        return
    end

    return kong.response.exit(503, {
        message = "rate limiter unavailable"
    })
end
```

## 7.3 Faults that must be covered

- Redis connection failure.
- Redis authentication failure.
- Redis SELECT failure.
- Redis EVAL execution failure.
- Redis timeout.
- Redis returning abnormal data.
- Lua script runtime errors.

All must be verified to fail closed.

Note:

A legitimate rate-limiting 429 must not be conflated with a Redis-fault 503.

---

# 8. HTTP Response Design

## 8.1 Normal admission

```http
HTTP/1.1 200 OK

X-RateLimit-Limit: 100
X-RateLimit-Remaining: 99
X-RateLimit-Reset: 1794384434
```

## 8.2 Quota exceeded

```http
HTTP/1.1 429 Too Many Requests

Content-Type: application/json
Retry-After: 36
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
```

Response body:

```json
{
  "message": "API rate limit exceeded",
  "limit": 100,
  "window": 3600,
  "retry_after": 36
}
```

## 8.3 Redis unavailable

```http
HTTP/1.1 503 Service Unavailable
```

Response body:

```json
{
  "message": "rate limiter unavailable"
}
```

## 8.4 Response header requirements

To verify:

- 429 must return Retry-After.
- 503 must not masquerade as normal rate limiting.
- With hide_client_headers=true, the rate-limiting response headers are not exposed.
- The meaning of reset must be consistent with the actual token bucket algorithm.

The current `reset = now + window` is an approximate display value; it does not mean the token bucket resets fully at reset.

It is recommended to clarify the header semantics later, to avoid misdescribing the token bucket as a fixed window.

---

# 9. Code Review of the Existing Implementation and Issues to Fix

The following are the places the current implementation needs careful checking.

## 9.1 redis.lua

Current module:

```text
lib/redis.lua
```

Responsible for:

- Redis connection.
- Authentication.
- Database selection.
- Lua execution.
- The keepalive connection pool.

Must check:

1. Whether connection failures are handled correctly.
2. Whether AUTH failure closes the connection.
3. Whether SELECT failure closes the connection.
4. Whether EVAL failure closes the connection.
5. Whether the connection is correctly returned to the pool after successful execution.
6. Whether keepalive failure is handled correctly.
7. Whether Redis return values are valid.
8. Whether rate, burst, want, and ttl receive full parameter validation.

Particular attention:

The Redis client connection pool must be compatible with the Kong/OpenResty execution model; an incorrectly managed Redis connection object must not be shared across requests.

## 9.2 algorithm.lua

Current module:

```text
lib/algorithm.lua
```

Responsible for:

- Building the rate-limiting key.
- Computing batch.
- Computing rate and burst.
- Local inventory consumption.
- Redis bulk drawing.
- The final rate-limiting decision.

The following logic needs focused checking.

### Issue A: error handling when Redis returns nil

The current debug code contains:

```lua
local granted, err = redis_mod.grant(...)

kong.log.notice(
    "[RL-DEBUG] redis_grant key=", key,
    " granted=", granted.granted,
    " tokens=", granted.tokens
)

if not granted then
    return nil, err
end
```

There is a clear problem here.

If the Redis call fails:

```lua
granted = nil
```

then:

```lua
granted.granted
```

directly raises a Lua exception.

It must first check:

```lua
local granted, err = redis_mod.grant(...)

if not granted then
    kong.log.err(
        "rate-limit-advanced: redis grant failed: ",
        tostring(err)
    )

    return nil, err
end
```

and only then log the successful result.

### Issue B: local inventory refill failure

Current:

```lua
if granted.granted > 1 then
    store.fill(
        key,
        granted.granted - 1,
        ttl_s
    )
end
```

Must check:

- Whether store.fill succeeds.
- Whether it can fail due to insufficient shared-dict capacity.
- Whether concurrent overwrite of the inventory can occur.
- Whether tokens already drawn from Redis can be lost.
- Whether there are correct error logs and metrics.

A local inventory write failure must not be ignored.

If the inventory cannot be saved, the handling of already-drawn tokens must be explicit, guaranteeing no over-admission.

### Issue C: concurrent deduction from the local inventory

It must be checked whether:

```lua
store.take(key)
```

is atomic.

The following non-atomic separated sequence must not be used:

```text
read inventory
check inventory
decrement inventory
write inventory back
```

With multiple workers accessing concurrently, the same token could be consumed twice.

An atomic operation suited to the OpenResty shared dict should be used.

### Issue D: consistency between the local inventory and the Redis state

It must be explicit that:

- Redis is responsible for global authorization.
- The local inventory is responsible for consuming already-authorized tokens.
- The local inventory cannot conjure tokens out of thin air.
- Local inventory expiry must not lead to over-admission.
- Redis key expiry must not keep old local inventory valid indefinitely.

This area is the most important architectural optimization direction going forward.

## 9.3 store.lua

This is a module requiring focused review.

The AI is required to first read the complete implementation, not to assume it is correct.

To verify:

1. Whether the shared dict name used is correct.
2. Whether multiple workers share the same inventory.
3. Whether simultaneous take calls from multiple requests are safe.
4. Whether fill can suffer concurrent overwrites.
5. Whether the inventory has a TTL.
6. Whether the TTL is coordinated with the Redis lease lifecycle.
7. How insufficient shared-dict space is handled.
8. Whether inventory leaks exist.

The current Kong configuration has been verified:

```nginx
lua_shared_dict kong_rl 32m;
```

All three nodes have this configuration.

Therefore the problem can no longer be attributed simply to the shared dict being unconfigured.

The actual operation semantics of `store.lua` must be examined further.

---

# 10. Problems Found and Conclusions from Previous Load Tests

This section is important; the AI must refer to the real test results.

## 10.1 Test environment

```text
Kong nodes: 3
Redis: 1
limit: 100
window: 3600
burst: 100
Total requests: 450
Planned requests per node: 150
VUS: 30
```

Test entry points:

```text
kong1: localhost:8030
kong2: localhost:8010
kong3: localhost:8020
```

## 10.2 batch=1 test

Test command:

```bash
./bench/quota.sh -l 100 -b 1 -p 150
```

Test result:

```text
allowed = 100
limited = 350
other = 0
total = 450
```

Across different test rounds, the three nodes' admitted counts differ.

But globally it is always:

```text
allowed = 100
```

Log statistics:

```text
Redis request count: 450
Local inventory hit count: 0
```

Conclusions:

- With batch=1, every request accesses Redis.
- The Redis Lua atomic deduction is effective.
- The three Kong nodes share the global quota.
- The global quota is not over-admitted.

This is the most important current correctness baseline.

## 10.3 batch=20 test

Test command:

```bash
./bench/quota.sh -l 100 -b 20 -p 150
```

The following results occurred:

First run:

```text
allowed = 10
limited = 440
```

Second run:

```text
allowed = 100
limited = 350
```

Third run:

```text
allowed = 82
limited = 368
```

Fourth run:

```text
allowed = 45
limited = 405
```

Subsequently also:

```text
allowed = 20
limited = 430
```

This shows that batch=20's quota utilization fluctuates noticeably.

## 10.4 The traffic distribution problem discovered

One test run:

```text
========== Global statistics ==========

allowed=20
limited=430
other=0

========== Per-node request distribution ==========

kong1:
requests=18
allowed=10
limited=8

kong2:
requests=17
allowed=10
limited=7

kong3:
requests=415
allowed=0
limited=415
```

Another run:

```text
kong1:
requests=150
allowed=100
limited=50

kong2:
requests=150
allowed=0
limited=150

kong3:
requests=150
allowed=0
limited=150
```

Another:

```text
kong1:
requests=150
allowed=0
limited=150

kong2:
requests=150
allowed=100
limited=50

kong3:
requests=150
allowed=0
limited=150
```

These results indicate:

**After bulk token drawing, tokens may be stranded concentratedly on some Kong nodes; other nodes, even while continuously receiving requests, cannot use the stranded nodes' local inventory.**

Points requiring focused analysis:

- How requests are distributed across the Kong nodes.
- How workers within a Kong node share the inventory.
- Whether a node has multiple independent inventory pools.
- Whether Redis has already granted tokens that the local inventory cannot make usable by other workers.
- Whether the local inventory suffers concurrent overwrites.
- Whether any node successfully drew tokens but subsequently lacked traffic.

One must not judge a specific bug merely because some node received few requests but issued many Redis requests.

Correlated analysis must use the complete logs and request distribution from the same test round.

Also, previously the following was used to collect logs:

```bash
docker compose logs --since=5m
```

This approach may include logs from earlier rounds.

Subsequent tests must guarantee the logs correspond only to the current round.

## 10.5 Theoretical judgments that need correcting

The current test script uses:

```text
shared-iterations
```

Each VU, via:

```javascript
const node = NODES[(__VU - 1) % NODES.length];
```

is pinned to one node.

Therefore:

`shared-iterations` must not be interpreted as each node receiving exactly 150 requests evenly.

Two independent tests must be provided going forward:

1. An evenly distributed three-node test.
2. An unevenly distributed three-node test.

The even test verifies basic correctness.

The uneven test verifies batch token stranding and utilization.

The two results must not be conflated.

---

# 11. SDD Phased Development Plan

The AI is required to execute strictly in the following order.

**Rewriting the entire plugin in one pass is prohibited.**

Each phase must complete:

1. Reading the relevant source code.
2. Analyzing the existing implementation.
3. Listing the discovered problems.
4. Proposing a minimal change plan.
5. Modifying the code.
6. Executing tests.
7. Producing a test report.
8. Waiting for manual acceptance before entering the next phase.

## Phase 0: Code Baseline and Architecture Review

Goal:

Fully understand the existing code first, without modifying business logic.

Files to read:

```text
rate-limit-advanced/
    handler.lua
    schema.lua
    lib/
        algorithm.lua
        redis.lua
        store.lua

bench/
    quota.sh
    common.sh

k6/
    quota.js
```

Output:

```text
reports/phase-0-baseline.md
```

Report content:

- Current module responsibilities.
- The current request call chain.
- The Redis Lua execution process.
- The local inventory operation process.
- Key generation rules.
- The batch mechanism.
- Currently known problems.
- A risk inventory.

Acceptance:

One must be able to fully explain a single request's flow from Kong access to the final 200, 429, or 503.

## Phase 1: Core Correctness Fixes

Goal:

Guarantee the algorithm's correctness first.

Check and fix:

1. The exception when Redis returns nil.
2. Redis error handling.
3. The Lua token bucket's time computation.
4. Clock rollback.
5. The burst cap.
6. Partial grant logic.
7. Atomic deduction from the local inventory.
8. Local inventory write failure.
9. TTL handling.
10. Fail-closed.

Tests:

### Test A: basic token bucket

```text
limit=100
window=3600
burst=100
batch=1
```

Expected:

The first 100 requests are admitted; when tokens run out, 429 is returned.

### Test B: concurrency correctness

Multiple Kong nodes access the same key concurrently.

Expected:

```text
allowed = 100
limited = 350
other = 0
```

### Test C: Redis fault

Stop Redis:

```bash
docker compose stop redis
```

Send requests.

Expected:

```text
HTTP 503
```

A 200 must not be returned.

Recovery:

```bash
docker compose start redis
```

### Test D: token refill

After waiting a while, request again.

Check that the refilled amount satisfies:

```text
tokens += elapsed * rate
```

and does not exceed burst.

Output:

```text
reports/phase-1-correctness.md
```

## Phase 2: Keys and Multi-Dimension Rules

Goal:

Guarantee that multi-dimension rate-limiting rules are stable and never collide on keys.

Test dimensions:

```text
ip
consumer
path
method
header
route
service
```

Test combinations:

```json
{
  "limit_by": ["ip"]
}
```

```json
{
  "limit_by": ["ip", "path"]
}
```

```json
{
  "limit_by": ["consumer", "path", "method"]
}
```

Verify:

1. The same dimension values generate the same key.
2. Different dimension values generate different keys.
3. Multi-dimension combinations do not mistakenly share a bucket.
4. namespace can distinguish rules.
5. The Redis hash tag format is correct.
6. A rule's related keys can land on the same Redis Cluster slot.
7. Special characters do not create key ambiguity.

Must preserve:

```text
kong:rl:{rl:p=<8-digit policy fingerprint>:<dimension>=<value>:...}
```

as the base format (`p=` fingerprint confirmed in Phase 2: policy parameters participate in key computation, see §3.1 for details).

Output:

```text
reports/phase-2-key-design.md
```

## Phase 3: Plugin Behavior and Error Handling

Goal:

Ensure the Kong plugin's behavior meets expectations.

Tests:

- Normal requests 200.
- Over-limit requests 429.
- Retry-After correct.
- Redis fault returns 503.
- Header hiding configuration effective.
- Consumer dimension effective.
- Path dimension effective.
- Route / Service dimensions effective.
- Missing configuration returns a reasonable error.
- Behavior correct after a configuration update.

Check:

```text
handler.lua
schema.lua
```

Especially check:

```lua
PRIORITY = 1002
```

The execution order of authentication and rate-limiting plugins must match the Consumer dimension design.

If Consumer ID rate limiting is needed, the authentication plugin must run first.

Output:

```text
reports/phase-3-plugin-behavior.md
```

## Phase 4: Shared Dict and Batch Optimization

Goal:

Optimize performance once correctness is stable.

First check:

```text
lua_shared_dict kong_rl 32m;
```

It has already been verified that all three nodes have:

```nginx
lua_shared_dict kong_rl 32m;
```

But it must continue to be verified whether the actual store.lua really uses that dict.

Focus:

1. Whether all workers use the same node-level inventory pool.
2. Whether multiple independent inventories exist.
3. Whether take is atomic.
4. Whether fill is atomic or has correct concurrency protection.
5. Whether the local inventory strands tokens.
6. Whether the inventory TTL is reasonable.
7. Whether old inventory is cleaned after rule changes.

### Test matrix

```text
limit=100
window=3600
burst=100
```

Run in order:

```bash
./bench/quota.sh -l 100 -b 1 -p 150
./bench/quota.sh -l 100 -b 5 -p 150
./bench/quota.sh -l 100 -b 10 -p 150
./bench/quota.sh -l 100 -b 20 -p 150
./bench/quota.sh -l 100 -b 50 -p 150
```

Repeat each group at least 10 times.

Collect statistics on:

- allowed.
- limited.
- other.
- Quota utilization.
- Redis grant count.
- local_hit count.
- local_fill count.
- Requests per node.
- Admissions per node.
- Inventory stranded per node.

Key optimization point:

**Over-admission risk must not be introduced for the sake of reducing Redis requests.**

At the same time, the local token stranding caused by bulk drawing must be solved.

Possible research directions:

- Local inventory lease lifecycle.
- Idle inventory reclamation.
- Adaptive batch adjustment.
- Inventory strategy under uneven traffic across nodes.

However, any inventory reclamation scheme must consider concurrency safety; the local inventory must not simply be added back to Redis without a duplicate-return prevention mechanism.

Output:

```text
reports/phase-4-batch-performance.md
```

## Phase 5: Engineering Tests and Final Acceptance

Goal:

Verify the system's reliability in a real multi-node deployment.

Test scenarios:

### Scenario 1: normal traffic

```text
3 Kong
1 Redis
limit=100
batch=1
```

Requirement:

Globally strictly no more than 100.

### Scenario 2: bulk drawing

```text
3 Kong
1 Redis
limit=100
batch=20
```

Requirement:

No global over-admission; record utilization and stranded inventory.

### Scenario 3: uneven traffic

For example:

```text
Kong1: 10%
Kong2: 10%
Kong3: 80%
```

Requirement:

Verify token stranding.

### Scenario 4: Redis fault

Requirement:

Fail-closed.

### Scenario 5: Kong node restart

Test:

- One node restarting.
- Multiple nodes restarting.
- A node losing its local inventory.
- Other nodes continuing to serve requests.

Requirement:

No global over-admission.

### Scenario 6: continuous token refill

Run continuously for a period of time.

Verify:

- rate correct.
- burst correct.
- TTL correct.
- No accumulated over-admission.

### Scenario 7: configuration change

Modify:

- limit.
- window.
- burst.
- batch.
- limit_by.

Check whether old inventory could pollute the new rule.

Output:

```text
reports/final-acceptance.md
```

---

# 12. Load Test and Log Requirements

## 12.1 Every test round must be isolated

Before each test:

```bash
docker compose restart kong1 kong2 kong3
```

Wait for Kong to fully start.

Then:

```bash
docker compose exec redis redis-cli FLUSHDB
```

Confirm Redis has been cleared.

Then run the load test.

Note:

`FLUSHDB` is for isolating the test environment only; it must not be used in production.

Each test round must use its own log file.

Logs mixed across rounds must not be used to compute a single round's Redis request count.

## 12.2 Log requirements

A unified structured record is recommended:

```text
request_id
kong_node
worker_pid
key
batch
granted
local_remaining
decision
redis_error
```

At minimum, distinguish:

```text
redis_grant
local_fill
local_hit
limited
redis_error
```

Logs must not directly output the raw content of sensitive headers.

## 12.3 Key metrics

Adding Prometheus metrics is recommended:

```text
rate_limit_requests_total
rate_limit_allowed_total
rate_limit_limited_total
rate_limit_redis_requests_total
rate_limit_redis_errors_total
rate_limit_local_hit_total
rate_limit_local_fill_total
rate_limit_local_tokens
rate_limit_grant_total
```

Suggested metric labels:

```text
node
decision
```

Do not use high-cardinality data such as full IPs, paths, or headers directly as Prometheus labels.

---

# 13. Final Test Report Format

Every phase must produce a report.

Use the unified format:

```markdown
# Test Report

## 1. Test Purpose

## 2. Changed Files

## 3. Changes Made

## 4. Test Environment

## 5. Test Parameters

## 6. Test Commands

## 7. Test Results

| Metric | Result | Expected | Status |
|---|---|---|---|
| allowed | | | |
| limited | | | |
| other | | | |
| Redis request count | | | |
| local_hit | | | |
| local_fill | | | |

## 8. Log Analysis

## 9. Problems Found

## 10. Risk Analysis

## 11. Acceptance Passed?

## 12. Suggestions for the Next Phase
```

All reports must be based on real execution results.

Fabricating test results is prohibited.

Unexecuted tests must be marked:

```text
NOT RUN
```

---

# 14. Acceptance Criteria for the Current Version

The first version must ultimately satisfy:

| Item | Acceptance criterion |
|---|---|
| Redis Lua | Atomic token bucket |
| Time | Use Redis TIME |
| burst | Never exceeds bucket capacity |
| batch=1 | Global quota strictly correct |
| batch=N | No over-admission |
| Keys | Support multi-dimension rule combinations |
| Hash tag | Correct use of the Redis Cluster hash tag |
| Shared dict | Shared by workers within the same Kong node |
| Local inventory | Atomic deduction |
| Redis fault | Fail-closed, 503 |
| Over-limit requests | 429 |
| Retry-After | Reasonably computed |
| TTL | Coordinated with the token lifecycle |
| Tests | Multi-node concurrency and fault tests |
| Reports | A real report produced each phase |

---

# 15. Development Execution Instructions for the AI

The following requirements must be strictly followed.

## 15.1 Development constraints

You are not to redesign a brand-new rate-limiting plugin.

You are to iterate on the existing `rate-limit-advanced` project.

The following are mandatory:

1. Rewriting all code in one pass is not allowed.
2. Modifying the Redis key format without analysis is not allowed.
3. Arbitrarily changing the existing token bucket semantics is not allowed.
4. Sacrificing global quota correctness for performance is not allowed.
5. Introducing unnecessary external dependencies is not allowed.
6. Skipping tests is not allowed.
7. Fabricating test reports is not allowed.
8. Ignoring the batch utilization fluctuation observed in existing load tests is not allowed.
9. Every change must state its reason.
10. Every phase must retain a rollback-capable version of the code.

## 15.2 Development process

Each phase follows this process:

```text
read the existing code
      |
      v
understand the current architecture
      |
      v
list problems and risks
      |
      v
propose a minimal change plan
      |
      v
wait for plan confirmation
      |
      v
modify the code
      |
      v
run unit tests
      |
      v
run integration tests
      |
      v
produce a test report
      |
      v
manual acceptance
      |
      v
enter the next phase
```

If the existing architecture has a major problem:

First describe the problem, the reproduction path, and the impact scope.

The core architecture must not be changed unilaterally.

## 15.3 The first execution task

For now, execute only:

**Phase 0: code baseline and architecture review.**

Do not modify any code yet.

Read the current project in full:

```text
handler.lua
schema.lua
lib/algorithm.lua
lib/redis.lua
lib/store.lua
bench/quota.sh
bench/common.sh
k6/quota.js
```

Answer, with focus:

1. What is the complete execution chain of a request?
2. Does Redis Lua guarantee atomic deduction?
3. Is store.take truly atomic?
4. Can store.fill suffer concurrent overwrites?
5. Are the three Kong nodes' inventories correctly isolated?
6. Do multiple workers on the same node share inventory?
7. Why does batch=20 show utilization fluctuation?
8. Are the Redis TTL and the local inventory lifecycle consistent?
9. Is the current fail-closed complete?
10. What other problems in the current implementation could cause over-admission, under-admission, or anomalous admission?

Output:

```text
reports/phase-0-baseline.md
```

and provide:

- The current architecture diagram.
- Module call relationships.
- A problem inventory.
- Risk levels.
- Suggestions for subsequent phased changes.

**Wait for manual confirmation before entering Phase 1.**

---

# Final Development Principles

The core of this project is not simply implementing a Redis counter.

What truly needs to be solved is:

**How to share a global token quota across multiple Kong nodes while reducing Redis access through local bulk leasing, and to guarantee quota correctness under uneven traffic, node failures, and concurrent races.**

First priority: correctness.

Second priority: distributed inventory management.

Third priority: performance optimization.

Fourth priority: engineering quality and observability.

Any performance optimization must be built on the foundation of verified correctness.