# Spec Delta

## ADDED Requirements

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
