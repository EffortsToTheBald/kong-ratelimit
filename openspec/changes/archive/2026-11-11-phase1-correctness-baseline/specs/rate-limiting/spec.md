# Spec Delta

## Purpose

Defines the core correctness behavior of a shared global token bucket quota across multiple Kong nodes: policy-identity isolation of buckets, quota boundaries of batch=1 strict mode and batch=N lease mode, token refill and time monotonicity, the default fail-closed policy for Redis failures, and the trust semantics of the IP dimension value. This capability is the authoritative behavioral contract for the `rate-limit-advanced` plugin's correctness.

Wording convention: **MUST** and **MUST NOT** are mandatory requirements; "should" is a recommendation; "may" is optional. The first requirement keyword of each Requirement carries an English annotation in parentheses to satisfy the validator.

## ADDED Requirements

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
