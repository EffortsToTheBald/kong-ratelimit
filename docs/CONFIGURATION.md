# Configuration Reference (schema.lua is the sole basis)

> All fields come from `kong/plugins/rate-limit-advanced/schema.lua`; this document does
> not include parameters outside the Schema.
> Internal constants (such as the Lease metadata TTL `LEASE_TTL_MS=3600000`) are **not
> user-configurable** and are not in this table.

## 1. Top-Level Fields

| Field | Type | Default | Purpose | Constraints |
|---|---|---|---|---|
| `limit` | integer | **required** | Requests allowed per window seconds (bucket rate rate=limit/window) | > 0 |
| `window` | number | 60 | Window length (seconds) | > 0 |
| `burst` | integer | 0 | Bucket capacity; 0 = follow limit (allows a full burst within one window) | 0 ≤ burst ≤ 100000000; `0 normalized to limit` (participates in the policy fingerprint) |
| `batch` | integer | 0 | Tokens drawn from Redis per request; **0 = auto (clamp(limit/50, 1, 50)); 1 = strict global consistency; >1 = Lease pre-authorization** | 0 ≤ batch ≤ 100000000; **excluded from the policy fingerprint**; must be 0/1 in rules mode |
| `limit_by` | array of string | ["ip"] | Rate-limiting dimensions, combinable | Each element ∈ {consumer, ip, path, method, header, route, service}; len≥1; **should be omitted in rules mode** (the Schema implements the mutual-exclusion check by comparing against the default: a non-default limit_by is rejected; the default `["ip"]` is indistinguishable from unset, so it may exist as the default value and be ignored); when `header` is present, `header_name` is required |
| `header_name` | string | none | Header name read when `limit_by` includes "header" | Conditionally required (missing ⇒ 400 at push) |
| `rules` | array of record | none | Multi-rule joint evaluation (α strong consistency) | ≤ 8 rules; the top-level `limit_by` should be omitted in rules mode (mutual-exclusion check basis as above); each rule has independent limit/window/burst/limit_by/header_name |
| `namespace` | string | "rl" | Namespace (isolates the global buckets of different configs) | — |
| `hide_client_headers` | boolean | false | Do not return the X-RateLimit-* headers | — |
| `fault_tolerant` | boolean | false | Redis failure policy: false=Fail-close (503); true=degraded fail-open admission (X-RateLimit-Status: degraded) | — |
| `redis.host` | string | "127.0.0.1" | Redis address | — |
| `redis.port` | integer | 6379 | Redis port | 1–65535 |
| `redis.password` | string | none | Authentication password (AUTH on connect; Kong 3.6 OSS supports secrets management: `referenceable` allows `{vault://...}` references, `encrypted` supports at-rest encryption — DB-less has no at-rest storage so it does not affect this repository; new E2E: test/redis-password-e2e.sh) | Wrong password ⇒ existing Fail-close semantics (503) |
| `redis.database` | integer | 0 | Logical database | 0–15 |
| `redis.timeout` | integer | 1000 | Connection/read-write timeout (ms); a timed-out GRANT is treated as an **uncertain result** | 1–60000 |
| `redis.key_prefix` | string | "kong:rl" | Redis key prefix | — |

### Per-Rule (rules[i]) Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `limit` | integer | **required** | That rule's quota |
| `window` | number | 60 | That rule's window |
| `burst` | integer | 0 | That rule's bucket capacity |
| `limit_by` | array | ["consumer"] | That rule's dimensions (composite key) |
| `header_name` | string | none | Required when that rule includes the header dimension |

## 2. What Determines the Three Modes

| Condition | Mode | Redis behavior | Local inventory |
|---|---|---|---|
| No rules and `batch=1` | Per-request authorization | EVALSHA token_bucket per request | None |
| No rules and `batch>1` | Lease pre-authorization | GRANT_LEASE when inventory is insufficient | Yes (Worker-private) |
| No rules and `batch=0` | Lease pre-authorization (auto) | Same as above, batch=clamp(limit/50,1,50) | Yes |
| With rules | Multi-rule atomic authorization | GRANT_MULTI per request (all-or-nothing) | None (batch must be 0/1) |

## 3. Policy Fingerprint and Config Changes

- **Participates in the fingerprint**: `limit / window / burst (after normalization) /
  limit_by order / header_name (only when the header dimension is present)`
- **Excluded**: `batch` (transport parameter — changing batch does not empty global
  buckets), behavior parameters other than `namespace`,
  `fault_tolerant`/`hide_client_headers`/`redis.*` (connection and presentation parameters)
- **Config-change semantics**: any fingerprint-participating field change ⇒ new Pool Key
  (the global bucket starts full; old buckets / old Lease records die naturally by TTL).
  Evaluate the business impact of the "quota reset" before changing config; switch
  `namespace` if you need to inherit remaining balance.
- **Old Pool lifecycle reclamation is implemented** (Gates 2/3: MAX_POOLS=10000/Worker,
  max_age=2×window expiry, idle 60s Timer reclamation; EXPIRED unconsumed inventory is
  counted into discarded and not returned; automatic RETURN is still Deferred)

## 3.1 Dimension Semantics: the Anonymous Fallback of consumer (Current V1)

- Unauthenticated requests (no consumer) fall back to the fixed value **`anon`** on the
  `consumer` dimension ⇒ **all anonymous users share the same quota**.
- **Evaluated changing it to `anon:<client_ip>` (Gate 6); the original behavior was kept**. Reasons:
  ① the IP retrieval matches the `ip` dimension's basis (`kong.client.get_forwarded_ip()`,
  an API that exists in Kong 3.6 and honors the `trusted_ips` config), but its
  **trustworthiness depends on the deployment's `trusted_ips` configuration** — in
  reverse-proxy scenarios it is untrusted by default, and forged headers would produce
  attacker-controlled key cardinality;
  ② splitting by IP would effectively turn the `consumer` quota into a consumer×ip
  dual-dimensional quota, **inconsistent with the consumer dimension's definition**;
  ③ when anonymous traffic needs to be split by IP, `ip` should be explicitly added to
  `limit_by` (existing capability, unambiguous semantics);
  ④ changing the dimension value would make existing anonymous buckets unreachable
  (quota reset).
- New guard test added: `algorithm-lease-unit` A2 asserts that the consumer dimension of
  unauthenticated requests takes the fixed value `"anon"` (keys like `:consumer=anon}`),
  guarding the "anonymous shared quota" behavior against unintended change.

## 4. Failure-Handling Related

- `fault_tolerant=false` (default): Redis failure/timeout ⇒ **503 Fail-close**; never
  disguised as 429
- `fault_tolerant=true`: degraded fail-open admission + `X-RateLimit-Status: degraded`
- `redis.timeout`: GRANT timeout ⇒ **uncertain result** (Redis may have executed the debit
  and created the Lease record): no retry, no local inventory registration, which can
  cause inventory loss (frozen semantics)
- 429 carries `Retry-After` (capped at window; multi-rule = the maximum of the
  insufficient rules' waits, capped)

## 5. Unsupported Configuration Combinations

| Combination | Result |
|---|---|
| `rules` non-empty + non-default `limit_by` | 400 at push (the Schema implements the mutual-exclusion check by comparing against the default `["ip"]`; in rules mode simply omit limit_by. Note: an explicit `["ip"]` is indistinguishable from the default and will pass this check and be ignored as the default value) |
| `rules` non-empty + `batch > 1` | 400 at push (strong-consistency mode has no Leases) |
| `rules` length > 8 | 400 at push |
| `limit_by` includes `header` but `header_name` is missing | 400 at push (top level and per-rule share the same semantics) |
| `limit` ≤ 0 / `window` ≤ 0 / `batch` out of range | 400 at push |
