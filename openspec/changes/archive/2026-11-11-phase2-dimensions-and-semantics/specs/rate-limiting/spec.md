# Spec Delta

## ADDED Requirements

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
