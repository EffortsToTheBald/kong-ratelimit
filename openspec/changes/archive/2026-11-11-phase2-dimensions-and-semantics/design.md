# Design

## Context

- Phase 1 (archived) landed 8 fixes such as the policy fingerprint, fail-closed default, batch=1 short-circuit, and timestamp monotonicity; the main spec `openspec/specs/rate-limiting/spec.md` already has 8 requirements. This change consists entirely of **ADDED** requirements and does not modify existing ones.
- Multi-dimensional semantics status: `algorithm.lua:dim_value()` already implements 7 dimension values (consumer/ip/path/method/header/route/service), but it has never been measured—especially the consumer dimension, which depends on the authentication plugin running first (key-auth 1250 > rate-limit-advanced 1002; priorities are already ordered by design).
- Verified in the Kong 3.6 container: the `entity_checks` framework exists (`kong/db/schema/init.lua:540-720`), and the `conditional` checker + `contains` validator (init.lua:332/402) can express "array contains X ⇒ another field required"; official examples are in `ip-restriction` (the `config.xxx` path) and `datadog` (conditional usage, the `custom_entity_check` fallback form).
- Log level fact: under `KONG_LOG_LEVEL=notice`, nginx does **not display info level**—the 429 decision log must use `kong.log.notice` (consistent with the existing RL-DEBUG) to be observable.
- The fast path of local inventory cannot compute the "next token time" locally with precision (inventory does not refill automatically; it must wait for another Redis grant)—the reset semantics must acknowledge that this is an approximation.

## Goals / Non-Goals

**Goals:**

- Turn "multi-dimensional support" from a code fact into verifiable behavior (7 dimensions + combinations, all with automated assertions).
- Close out the 5 P1 semantics/observability items: reset semantics, Retry-After cap, 429 logs, header_name pre-validation, Redis defensive validation; plus the shared dict degradation warning (P1-8) and the remaining basis documentation (P1-3).
- Do not break existing load tests: the default `kong.yml` deployment and the bench harness behavior are unchanged.

**Non-Goals:**

- EVALSHA+NOSCRIPT: a performance optimization, assigned to Phase 4 (this change does not touch redis.lua's invocation).
- Prometheus metrics (Phase 5), the local inventory recovery protocol (Phase 4, which needs stranded data as design input).
- Path normalization/dimension cardinality governance: changes bucket identity semantics; needs an independent design.
- Multi-rule joint decision (multiple buckets per request): explicitly unsupported (review §5).

## Decisions

### D1. `X-RateLimit-Reset` = the Unix second at which the next token becomes available

- **Slow path (Redis)**: the script unifies the wait formula as `wait = max(0, (1 - tokens) / rate)` (0 when tokens≥1 = "the next token is already available"), and the handler computes `reset = now + wait`. The current script only computes wait when tokens<1; change it to always compute (a pure formula unification, no extra RTT).
- **Fast path (local inventory)**: `remaining > 0` → `reset = now` (locally, the next token is already available); `remaining == 0` (just took the last one) → `reset = now + ⌈1/rate⌉` (an approximation: wait one refill period; the local side cannot precisely know when Redis will grant again, so take a conservative value and document "this node's perspective").
- Keep the Unix seconds format (consistent with Kong's official plugin, no change to client parsing habits); the "remaining seconds" format was the second candidate and was rejected (breaks compatibility).
- The "time until the bucket is full again" scheme was rejected: when burst far exceeds the remainder, the value is huge (e.g., 99.5/0.028≈3600s) and gives clients no retry value.
- The alternative "display the global remainder per remaining" was rejected (needs an extra RTT; recorded in the review).

### D2. `Retry-After` cap = window

- Handler side: `retry_after = min(max(1, ceil(wait)), floor(window))`.
- Rationale: `rate = limit/window` ⇒ at least 1 token refills within a window, so a Retry-After exceeding window is meaningless.
- For extreme configurations (limit=1/window=3600), Retry-After stays 3600; a smaller rate is impossible (the rate lower bound is 1/window). Combined with D1, in a 429 response `Reset − now ≈ Retry-After`.

### D3. Redis return value defensive validation → failure branch

- `redis.lua:grant()` validates before parsing the EVAL result: `type(res) == "table"`, `#res == 3`, `granted = tonumber(res[1])` not nil and `0 ≤ granted ≤ want`, and tokens/wait tonumber-able. Any failure → `r:close()` + `return nil, "malformed eval response"`.
- The validation logic is extracted as a pure function `parse_grant_response(res, want)` (no cosocket dependency); malformed-data tests are fed samples directly by resty unit tests (E2E cannot inject malformed returns; recorded truthfully).
- **Chose the failure branch rather than the review's original suggestion "treat as a rejection (429)"**: a 429 is a deterministic algorithm output and should not be triggered by data anomalies; a malformed return means Redis state is untrustworthy, so the fail-closed(503)/degraded branch makes the policy explicit. The run_with_invalid semantics are consistent with the fail-closed default.

### D4. `header_name` pre-validation: entity_checks (conditional + contains)

```lua
entity_checks = {
  { conditional = {
      if_field = "config.limit_by",
      if_match = { contains = "header" },
      then_field = "config.header_name",
      then_match = { required = true },
  } },
}
```

- Verified that all three pieces exist: the `entity_checks` array mechanism (init.lua:540-575 docs), the `conditional` checker (init.lua:694-720), and the `contains` validator (init.lua:332, registered at 402); official plugin examples: `ip-restriction` (the top-level `config.xxx` path), `datadog` (the conditional form).
- Fallback (if contains does not work on arrays): `custom_entity_check` + `field_sources` (the datadog:141-145 form). Further fallback: keep the runtime 500—in that case the spec's "400 at deployment" scenario would need a fallback revision, **and this must be measured first on implementation day one**.
- The runtime backstop validation (inside build_key) is retained: a double guard against paths that bypass schema validation (e.g., vault references).

### D5. Shared dict degradation warning: `init_worker`

- `handler.lua` adds `function _M:init_worker()`: when `store.backend()` is not `shared_dict`, emit `kong.log.warn("rate-limit-advanced: lua_shared_dict kong_rl is unavailable; local inventory degrades to a worker-private table (reduced precision)")`.
- init_worker has no conf parameter (a Kong global phase), but `backend()` does not need conf.
- The degraded behavior itself is unchanged (running degraded on a worker table); only observability is added.

### D6. Consumer dimension verification plan: dims.sh ships its own auth configuration

- Do not touch `kong.yml` (to avoid forcing authentication site-wide and breaking existing load tests). The consumer scenario of `bench/dims.sh` deploys a complete declarative configuration itself:
  - Service echo + two routes: `/echo` (no authentication, behavior unchanged), `/echo-auth` (with key-auth attached);
  - consumers: `alice`, `bob`, each holding a keyauth credential;
  - rate-limit-advanced attached to the `/echo-auth` route with `limit_by=[consumer]`.
- The priority order (key-auth 1250 before 1002) is confirmed by measurement in that scenario.
- The other 6 dimension scenarios attach to `/echo` (no authentication), each with an independent namespace + FLUSHDB.

### D7. `bench/dims.sh` structure (automated multi-dimensional verification)

- Reuses the `xff.sh` pattern: `mk_json` to build configurations, `apply_config`, count assertions, explicit PASS/FAIL.
- Scenarios: ① `[ip,path]` two paths independent; ② `[method]` GET/POST bucketed separately; ③ `[header]` dual tenants + missing sentinel; ④ `[route]` key contains route.id; ⑤ `[service]` key contains service.id; ⑥ `[consumer]` (key-auth dual consumers + anon); ⑦ different dimension order yields different fingerprints (assert via the `policy_fingerprint` pure function).
- Each scenario prints PASS/FAIL; any FAIL makes the script exit 1.

### D8. 429 logging and the remaining basis

- 429 branch: `kong.log.notice("rate-limit-advanced: 429 key=", key, " limit=", conf.limit, " batch=", batch)` (notice level is required to be visible under KONG_LOG_LEVEL=notice).
- The `remaining` basis: code comments + README/design state "both paths are this node's perspective" (Phase 1 verified that the slow path's granted−1 is the local inventory after fill); no behavior change.

### D9. rule.md key format sync

- The examples and explanations of §3.2/§3.3/§3.4 add the `p=<8-char hex>` fingerprint: the format, inputs (limit/window/parsed burst/limit_by/header_name), the cost "a policy change means a new bucket", and the namespace escape hatch. An author document, confirmed for inclusion in this change.

## Risks / Trade-offs

- [conditional+contains does not work on arrays] → measure deployment on implementation day one; fallback to `custom_entity_check`; if that fails too, fall back to the runtime 500 and revise the spec scenario (the risk chain is annotated; other tasks unaffected).
- [reset=now misread by clients as "the window has reset"] → the semantics are "the next token is already available"; README/design explicitly state the basis and the token bucket model, not pretending to be a fixed window.
- [The ⌈1/rate⌉ approximation of fast-path reset] → the local side cannot precisely know when Redis will grant again; take a conservative value; the docs acknowledge this node's perspective.
- [429 logs amplify log volume under high rejection rates] → single-line notice-level logs, of comparable magnitude to the existing RL-DEBUG; unified governance when Phase 5 does structured logging.
- [Leftover key-auth configuration deployed by dims.sh] → any subsequent quota.sh/matrix.sh run overwrites it wholesale with its own generated configuration; no persistent impact; dims.sh does not actively clean up at the end (consistent with the other scripts' behavior).
- [The defensive validation misjudges extreme but legal returns] → the validation surface covers only the EVAL return structure (3-element array, numeric ranges), not business semantics; `granted ≤ want` is guaranteed by the script and tightened as a defensive assertion.

## Migration Plan

1. Baseline commit (continuing the group-level commit convention).
2. Code changes (D1-D5, D8), self-tested item by item: resty pure-function unit tests (parse_grant_response, fingerprint order) + in-container measurements (reset/cap/429 logs/400 deployment/degradation warning).
3. Write `bench/dims.sh` and run all scenarios (7 scenarios all green).
4. Docs sync (README, design.md, rule.md).
5. Integration acceptance: re-run all cases + the Phase 1 batch=1 baseline regression (confirming no regression) → `reports/phase-2-dimensions-and-semantics.md` (§13 format).
6. Rollback: reverting the group-level commit suffices; the response header semantic change has no persistence impact.

## Open Questions

(None blocking. The measured result of entity_checks determines D4's main plan/fallback choice; it is a day-one fact check and has been moved up front in the tasks.)
