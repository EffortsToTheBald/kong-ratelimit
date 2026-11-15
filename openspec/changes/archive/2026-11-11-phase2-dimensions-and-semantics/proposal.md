# Proposal

## Why

The MVP requirements mandate "multi-dimensional control granularity covering Request Path / Client ID / IP, etc.", but Phase 1 only measured `limit_by=[ip]`—the multi-dimensional semantics were in the "code supports it, unproven" state; meanwhile, among the P1 batch of review-phase-0, 5 items of externally visible semantics/observability problems (misleading reset header semantics, unbounded Retry-After, no log for 429, bad configuration only surfacing as a runtime 500, no defense against malformed Redis returns) directly affect the credibility of the delivery documents. This change closes both categories in one go.

## What Changes

- **Full-dimension verification of multi-dimensional rate limiting**: add `bench/dims.sh` covering `[ip]`, `[ip,path]`, `[consumer,path,method]`, `[header]`, `[route]`, `[service]`, and combinations—verifying that different dimension values count independently, the same policy stably maps to the same key, and no buckets are unexpectedly shared. The consumer dimension depends on authentication: the script ships its own key-auth + two-consumer complete declarative configuration (**the default deployment of `kong.yml` is untouched**, and existing load-test behavior is unaffected).
- **`X-RateLimit-Reset` semantics fix** (**BREAKING** response header semantics): changed from "a pseudo-window value of now + window" to "**the Unix second at which the next token becomes available**", on the same basis as `Retry-After` (a token bucket has no window-reset concept; the old value gives clients no useful guidance).
- **`Retry-After` cap**: capped at `window` seconds (≥1 token always refills within the window), eliminating Retry-After values of thousands of seconds in low-rate scenarios (**BREAKING**: response values change in extreme configurations).
- **429 observability**: at the access phase, an info log for every rejected request (key/limit/batch), so "deterministic rate-limit rejections" can be distinguished from "Redis failures" in logs.
- **`header_name` configuration pre-validation** (**BREAKING**: a bad configuration changes from "deployed successfully + runtime 500" to "rejected with 400 at deployment"): schema `entity_checks` (`conditional` + `contains`, verified as supported in the Kong 3.6 container with official examples).
- **Defensive validation of Redis return values**: the EVAL return value must be a 3-element array with valid numbers, otherwise it is treated as a Redis anomaly and takes the failure branch (default 503 / explicit fault-tolerance degraded); admission or rejection must not be based on untrusted data.
- **Shared dict degradation warning**: `init_worker` checks `store.backend()`; when degraded to a worker-private table, `log.warn` is emitted at startup (previously silent degradation).
- **`remaining` basis documented**: both fast and slow paths are actually "this node's perspective" (verified in Phase 1); this item is documentation + comment clarification with no behavior change.
- **`rule.md` §3.2/§3.3 key format sync**: add the `p=` policy fingerprint explanation (author document, updated with this change).

## Capabilities

### New Capabilities

(None)

### Modified Capabilities

- `rate-limiting`: ADDED requirements for multi-dimensional rate-limiting semantics (value sources and bucketing behavior per dimension), response header semantics (Reset/Retry-After), observability (429 logs, degradation warning), defensive behavior (malformed Redis returns take the failure branch), and configuration pre-validation (header_name). The existing 8 requirements (merged into the main spec in Phase 1) are unchanged.

## Impact

- **Code**: `kong/plugins/rate-limit-advanced/{schema.lua, handler.lua, lib/redis.lua}`; `lib/algorithm.lua` only comment/value-passing tweaks
- **Tests**: add `bench/dims.sh` (multi-dimensional verification, with its own key-auth scenario configuration); the existing harness is unaffected
- **Docs**: `README.md` (response header semantics), `docs/design.md` (§7 response headers/§9 trade-offs), `rule.md` (§3.2/§3.3 key format)
- **Behavioral impact**: the numeric meaning of the reset header changes; `Retry-After` becomes smaller in extreme scenarios; bad configurations are rejected with 400 at deployment; malformed Redis returns change from "possibly 500/exception" to a deterministic failure branch
- **Explicitly not doing** (left to later changes): EVALSHA+NOSCRIPT (assigned to the Phase 4 performance batch), Prometheus metrics (Phase 5), local inventory recovery (Phase 4), path normalization/cardinality governance (needs an independent design), multi-rule joint decision
