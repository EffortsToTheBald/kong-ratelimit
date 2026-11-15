# rate-limiting Specification

## Purpose

Defines the core correctness behavior of a shared global token bucket quota across multiple Kong nodes: policy-identity isolation of buckets, quota boundaries of batch=1 strict mode and batch=N lease mode, token refill and time monotonicity, the default fail-closed policy for Redis failures, and the trust semantics of the IP dimension value. This capability is the authoritative behavioral contract for the `rate-limit-advanced` plugin's correctness.

Wording convention: **MUST** and **MUST NOT** are mandatory requirements; "should" is a recommendation; "may" is optional. The first requirement keyword of each Requirement carries an English annotation in parentheses to satisfy the validator.

## Requirements

### Requirement: Rate-limit buckets are isolated by policy fingerprint
The system MUST derive a policy fingerprint for each rate-limiting policy (determined jointly by the parsed values of limit, window, and burst, the limit_by dimension list, and header_name) and encode it inside the hash tag of the Redis key. Different policies MUST yield mutually independent buckets; the same policy MUST map stably to the same bucket.

#### Scenario: Configuration change does not inherit the old quota
- **WHEN** a running limit=1000 configuration is changed to limit=100 and an over-quota request is issued immediately
- **THEN** the global admitted count does not exceed the new limit (the old bucket or leftover tokens in old local inventory are not inherited)

#### Scenario: The same policy maps to the same key across nodes
- **WHEN** three Kong nodes are configured with an identical rate-limiting configuration and serve requests with identical dimension values
- **THEN** all three nodes hit the same Redis key (exactly one bucket globally)

### Requirement: batch=1 is the strict global-consistency mode
When batch=1, the system MUST request tokens atomically from Redis for every request, and MUST NOT deduct from local inventory or write to local inventory.

#### Scenario: batch=1 admits exactly limit globally
- **WHEN** 3 nodes with batch=1, limit=100, window=3600 each send 150 concurrent requests (450 total)
- **THEN** the global admitted count is exactly 100, the rate-limited count is exactly 350, the error count is 0, and the local inventory hit count is 0

#### Scenario: batch=1 produces no local inventory
- **WHEN** after a round of batch=1 load testing, each node's local inventory is inspected
- **THEN** the local inventory for this policy key does not exist or is empty

### Requirement: batch=N mode does not over-admit
When batch=N (N>1), the system MUST ensure the number of admitted requests does not exceed the tokens authorized by the Redis global bucket; no node may obtain extra quota independent of the global bucket.

#### Scenario: batch=20 admits no more than limit
- **WHEN** 3 nodes with batch=20, limit=100, window=3600 (refill rate negligible within the duration of a single test round) each send 150 concurrent requests
- **THEN** the global admitted count does not exceed 100

#### Scenario: Node count does not amplify quota
- **WHEN** the number of participating Kong nodes is increased or decreased while the policy stays unchanged
- **THEN** the global quota semantics are unchanged (the admission upper bound is still determined by the global bucket, independent of node count)

### Requirement: batch=N mode under-admission has an engineering bound
When batch=N (N>1) and the local inventory lifecycle is managed correctly, under-admission caused by inventory stranding MUST satisfy: per-round global admitted count ≥ max(0, limit − node count × batch). This bound is an engineering acceptance reference (assuming negligible refill during the test and a single inventory pool per node).

#### Scenario: batch=20 reaches the lower bound under uniform traffic
- **WHEN** 3 nodes with batch=20, limit=100 uniformly send 450 concurrent requests
- **THEN** the global admitted count ≥ max(0, 100 − 3×20) = 40

### Requirement: Fail-closed by default when Redis is unavailable
When fault_tolerant is at its default (false) and Redis is unavailable (connection failure, authentication failure, EVAL failure, timeout, or malformed return data), the system MUST reject the request with HTTP 503 and MUST NOT forward the request upstream.

#### Scenario: Default 503 after stopping Redis
- **WHEN** a request is sent after stopping Redis and the configuration does not explicitly set fault_tolerant
- **THEN** the response is HTTP 503 and upstream did not receive the request

#### Scenario: Redis failures MUST NOT produce HTTP 500
- **WHEN** Redis returns an error, times out, or returns an abnormal value during request processing
- **THEN** the response code can only be 200/429/503; 500 never occurs

### Requirement: Explicit fault-tolerant mode admits and marks degraded
When fault_tolerant=true and Redis is unavailable, the system MUST admit the request and set the response header X-RateLimit-Status: degraded.

#### Scenario: Fault-tolerant mode degrades and admits
- **WHEN** a request is sent after stopping Redis and the configuration explicitly sets fault_tolerant=true
- **THEN** the request is admitted and the response header contains X-RateLimit-Status: degraded

### Requirement: Token refill is based on Redis time and timestamps are monotonic
The system MUST use Redis server-side time to compute token refill (tokens += elapsed × rate, capped at burst), and the refill timestamp inside the bucket MUST NOT go backward—during a clock rollback, tokens MUST NOT be granted twice for the same time period.

#### Scenario: Refill amount matches the rate formula and is capped at burst
- **WHEN** after the bucket is exhausted, wait a known duration t before sending a request
- **THEN** the number of newly available tokens does not exceed ⌈t × rate⌉, and the tokens in the bucket do not exceed burst

#### Scenario: Timestamps do not go backward; rollback does not double-bill
- **WHEN** a request is sent after the bucket's refill timestamp has been preset to a future moment
- **THEN** no refill occurs this time, and the timestamp inside the bucket keeps its original value and is not overwritten with an earlier time

### Requirement: The ip dimension value follows Kong realip trust semantics
The value of the ip dimension MUST be the client address resolved under the Kong realip configuration (the direct peer IP when trusted_ips is not configured); a spoofed X-Forwarded-For from an untrusted peer MUST NOT change the value of the ip dimension.

#### Scenario: Spoofed XFF does not create a new bucket
- **WHEN** requests from the same source IP carry arbitrary spoofed X-Forwarded-For headers and are sent with limit=1, batch=1
- **THEN** only the first request is admitted; subsequent requests with different spoofed XFF values all return 429 (always hitting the same bucket)


### Requirement: Multi-dimensional combinations count independently
The limit_by dimension combination MUST participate in the hash tag computation of the Redis key: different dimension combinations map to different buckets; the same combination with the same dimension values maps stably to the same bucket; any differing dimension value means a different bucket.

#### Scenario: Under the ip+path combination, different paths count independently
- **WHEN** configured with limit_by=[ip, path], limit=2, request /echo and /echo/foo 2 times each in sequence
- **THEN** each path admits 2 requests (the 3rd request to the same path returns 429), with no quota shared between them

#### Scenario: Different dimension order means different buckets
- **WHEN** configurations with identical values are deployed as limit_by=[ip, path] and limit_by=[path, ip] respectively
- **THEN** they produce different fingerprints and different keys, sharing no bucket

### Requirement: The method dimension buckets by HTTP method
The method dimension MUST use the request's HTTP method as its value in key computation.

#### Scenario: GET and POST are bucketed separately
- **WHEN** configured with limit_by=[method], limit=1, send GET first then POST
- **THEN** both requests are admitted (the first for each method bucket); a second request with the same method then returns 429

### Requirement: The header dimension buckets by the designated header's value
The header dimension MUST use the value of the header designated by `header_name` as the dimension value; requests missing that header MUST share the same missing-value sentinel bucket, not shared with any named-value bucket.

#### Scenario: Different header values are bucketed separately; missing values share the sentinel
- **WHEN** configured with limit_by=[header], header_name=X-Tenant, limit=1, send X-Tenant: a and X-Tenant: b once each, then once more each, and finally send 2 consecutive requests without the header
- **THEN** a and b are both admitted the first time and each returns 429 on the second; the first "headerless" request is admitted (its own sentinel bucket) and the second "headerless" request returns 429; headerless requests do not consume the buckets of a/b

### Requirement: The consumer dimension buckets by authenticated identity
The consumer dimension MUST use the consumer identity resolved by the authentication plugin as its value; unauthenticated requests share the anon sentinel bucket.

#### Scenario: After authentication, different consumers have independent quotas
- **WHEN** the route has key-auth enabled, consumers alice/bob each hold a valid key, configured with limit_by=[consumer], limit=1
- **THEN** alice's and bob's first keyed requests are each admitted and their seconds return 429; their quotas do not affect each other

#### Scenario: Unauthenticated requests share the anon bucket
- **WHEN** with the same configuration, send requests without a key
- **THEN** all of them are counted into the anon bucket (not shared with the alice/bob buckets)

### Requirement: route/service dimensions participate in key computation
The route and service dimensions MUST use the matched route.id / service.id as their value in key computation; a sentinel value is used when there is no match.

#### Scenario: The route dimension takes effect
- **WHEN** configured with limit_by=[route], limit=1 and the request matches an existing route
- **THEN** the key contains that route's id value, the first request is admitted and the second returns 429

### Requirement: Pre-validation of the header dimension's header_name configuration
A configuration where limit_by includes header but header_name is missing/empty MUST be rejected at configuration deployment time (HTTP 400) and MUST NOT enter runtime.

#### Scenario: A bad configuration is rejected at deployment
- **WHEN** a plugin configuration with limit_by=[header] and no header_name is submitted to the Admin API
- **THEN** the Admin API returns 400 explaining that header_name is required (no more 500s at runtime)

### Requirement: X-RateLimit-Reset is the moment the next token becomes available
X-RateLimit-Reset MUST be "the Unix second at which the next token becomes available": on the Redis grant path it is derived from the wait duration returned by the server; on the local inventory path it is from this node's perspective (having inventory counts as currently available); this MUST be consistent with Retry-After (on 429, Reset−now ≈ Retry-After).

#### Scenario: On 429, reset and Retry-After use the same basis
- **WHEN** a 429 is received after the bucket is exhausted
- **THEN** X-RateLimit-Reset is some future Unix second, and its difference from the response moment equals the Retry-After seconds (±1 second tolerance)

### Requirement: Retry-After has an upper bound
Retry-After MUST NOT exceed the configured window seconds.

#### Scenario: Retry-After is capped under a small rate configuration
- **WHEN** configured with limit=1, window=3600, trigger a 429
- **THEN** Retry-After ≤ 3600 (no wait value exceeding window appears)

### Requirement: 429 rejections are observable
Every request rejected with 429 MUST produce a log entry containing the rate-limiting key, limit, and batch, so that rate-limit rejections can be distinguished from Redis failures.

#### Scenario: 429 produces a decision log
- **WHEN** a request is rejected for exceeding the quota
- **THEN** the log contains the request's key and limit information, and can be distinguished from the 503 failure path by log search

### Requirement: Malformed Redis returns take the failure branch
When the Redis EVAL return value is not a 3-element numeric array, it MUST be treated as a Redis anomaly: return nil and enter the failure branch (default 503 / explicit fault-tolerance degraded), and MUST NOT admit, reject, or throw a Lua exception based on malformed data.

#### Scenario: Malformed returns produce neither 500 nor erroneous admission
- **WHEN** Redis returns malformed data for EVAL (e.g., an empty table or non-numeric values)
- **THEN** the request gets 503 (default configuration) or a degraded admission (explicit fault tolerance), the log records a defensive validation failure, and there is no Lua traceback

### Requirement: Startup warning when shared dict is missing
When lua_shared_dict is unavailable and the local inventory degrades to a worker-private table, the system MUST output a warning log during the startup phase.

#### Scenario: A degraded configuration warns at startup
- **WHEN** Kong is started with KONG_NGINX_HTTP_LUA_SHARED_DICT removed
- **THEN** the startup log contains a warning about local inventory degradation, and the feature still runs degraded on worker tables

### Requirement: Multi-rule joint decision is an all-or-nothing atomic operation
A request is simultaneously constrained by all rules declared in `rules`: when all rule buckets have tokens, the system MUST consume 1 token from each bucket and admit the request; when any rule bucket lacks tokens, the system MUST reject the request and **no bucket is consumed**—the check and deduction MUST be completed atomically in a single script on the Redis server side.

#### Scenario: One bucket empty, one bucket non-empty ⇒ reject and both buckets unchanged
- **WHEN** rule R1's (consumer global) bucket is preset with tokens=0 and rule R2's (consumer×path) bucket with tokens=5, then a request hitting both rules is issued
- **THEN** the response is 429, and the tokens of both R1 and R2 buckets are unchanged before and after the request (R2 is not consumed)

#### Scenario: All buckets have tokens ⇒ deduct 1 from each and admit
- **WHEN** a request is issued while both R1 and R2 buckets have ≥1 token
- **THEN** the request is admitted, and each bucket's tokens decrease by exactly 1

### Requirement: Group key structure and group fingerprint
All buckets of a multi-rule configuration MUST fall within the same hash tag (`kong:rl:{<ns>:<group fingerprint>:r<i>:…}`); the group fingerprint is derived from all rule parameters jointly; any change to a rule parameter MUST cause the whole group to map to new keys (old buckets expire via TTL).

#### Scenario: Modifying any rule ⇒ the whole group changes buckets
- **WHEN** rules are deployed under the same namespace with only one rule's limit modified
- **THEN** the group fingerprint segment of all rules' bucket keys changes (the old group's buckets are no longer hit)

#### Scenario: Buckets within a group share the same hash tag
- **WHEN** all bucket keys involved in one request are inspected
- **THEN** the hash tag content of every key is identical (the precondition of the same Redis Cluster slot)

### Requirement: Configuration constraints of the strong-consistency mode
The `rules` mode MUST satisfy the following configuration constraints, with violations rejected at deployment time (HTTP 400): `rules` and `limit_by` MUST NOT be declared explicitly at the same time (mutually exclusive); when `rules` is non-empty, `batch` MUST be 0 or 1 (no lease semantics); the number of rules MUST NOT exceed 8.

#### Scenario: Three kinds of bad configurations are rejected at deployment
- **WHEN** configurations a) rules and limit_by co-present, b) rules non-empty with batch=20, c) 9 rules, are deployed one by one
- **THEN** all three deployments return 400 with an explanation

#### Scenario: A legal rules configuration deploys normally
- **WHEN** a legal configuration with 2 rules and batch=0 is deployed
- **THEN** the deployment succeeds (2xx)

### Requirement: Multi-rule response semantics
In multi-rule mode: on admission, `X-RateLimit-Remaining` MUST be the minimum of the buckets' remainders (the bottleneck rule), and `X-RateLimit-Reset` MUST be the next-token-available moment of the bottleneck rule; the 429 response body MUST contain a `rule` field identifying the insufficient rule, and `Retry-After` MUST be the maximum of the wait values across the insufficient rules (capped at the maximum of the corresponding windows).

#### Scenario: The bottleneck rule determines the response headers
- **WHEN** a multi-rule request is admitted (R1 remainder 3, R2 remainder 1)
- **THEN** X-RateLimit-Remaining is 1 (bottleneck), and Reset corresponds to R2's next-token moment

#### Scenario: 429 identifies the rejected rule and the wait
- **WHEN** R1 is empty and R2 has 5 tokens, and the request is rejected
- **THEN** the response body's `rule` points to R1, and Retry-After ≤ R1's window

### Requirement: Single-rule form behavior does not regress
When `rules` is not configured (only `limit_by`), the system MUST retain all existing behavior: single-bucket composite keys, local inventory batch leases, and existing response header semantics.

#### Scenario: Regression of the old configuration
- **WHEN** the batch baseline is re-run with Phase 2's existing configuration (limit_by=[ip], batch=20)
- **THEN** the result matches the existing acceptance anchor (450 requests; exactly 100 admitted at batch=1)
