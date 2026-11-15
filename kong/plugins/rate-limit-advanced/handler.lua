-- ============================================================
-- rate-limit-advanced / handler.lua
-- access phase: decide whether to allow. Running in access means over-limit requests never reach the upstream.
-- ============================================================
local algorithm = require "kong.plugins.rate-limit-advanced.lib.algorithm"
local lease = require "kong.plugins.rate-limit-advanced.lib.lease"

local _M = {
  -- Above most business plugins so rate limiting runs before business logic (key-auth is 1250; being below it
  -- means authentication runs first, then limiting, enabling per-consumer counting)
  PRIORITY = 1002,
  VERSION = "0.2.0",
}

-- V1 lease model (Phase 6): inventory = worker-private Lua table (lease.lua),
-- no shared dict; local TAKE is zero-IO and Redis failure semantics are decided only by the GRANT path
-- (Fail-close/Fail-open branches unchanged from the batch=1 era, see the nil-decision branch in access).
-- Legacy shared-dict aggregate inventory (store.lua) was removed in Phase 8 batch A.
function _M:init_worker()
  kong.log.notice("rate-limit-advanced: V1 lease mode (worker-private table, no shared dict)")
  -- Gate 3 (frozen §4): low-frequency fallback Timer in init_worker (60s, module-level duplicate-registration guard);
  -- only handles idle pools (last_used older than max_age), disjoint from the request-path set.
  local tok, terr = lease.start_sweep_timer()
  if not tok then
    kong.log.warn("rate-limit-advanced: sweep timer not started: ", tostring(terr))
  end
end

function _M:access(conf)
  local key, kerr = algorithm.build_key(conf)
  if not key then
    kong.log.err("rate-limit-advanced: bad config: ", kerr)
    return kong.response.exit(500, {
      message = "rate-limit-advanced: misconfigured",
      detail  = kerr,
    })
  end

  local decision, derr = algorithm.check(conf, key)

  -- Two paths when Redis is unavailable: allow (explicit fault tolerance) or 503 (default fail-closed)
  if not decision then
    if conf.fault_tolerant then
      kong.log.warn("rate-limit-advanced: limiter unavailable, failing open: ", derr)
      kong.response.set_header("X-RateLimit-Status", "degraded")
      return
    end

    kong.log.err("rate-limit-advanced: limiter unavailable, failing closed: ", derr)
    return kong.response.exit(503, {
      message = "rate limiter unavailable",
    })
  end

  -- D5: in multi-rule mode the reported limit = the bottleneck/rejecting rule's limit (single-rule path keeps conf.limit)
  local shown_limit = decision.multi_limit or conf.limit

  if not decision.allowed then
    -- 429: deterministic rate-limit rejection; emit a decision log (notice level, visible when KONG_LOG_LEVEL=notice),
    -- so "deterministic rejection" can be distinguished from Redis failures (fail-branch logs).
    kong.log.notice("rate-limit-advanced: 429 key=", key,
                    " limit=", shown_limit,
                    " batch=", algorithm.resolve_batch(conf),
                    decision.reject_rules and (" reject=" .. decision.reject_rules) or "")

    -- D2: Retry-After cap (single rule = window; multi-rule = max window of insufficient rules, same convention)
    local retry_after = math.max(1, math.ceil(decision.retry_after or 1))
    local window_cap = decision.reject_cap or math.floor(conf.window)
    if window_cap < 1 then
      window_cap = 1
    end
    if retry_after > window_cap then
      retry_after = window_cap
    end

    -- D1: Reset uses the same convention as Retry-After — the Unix second when the next token becomes available
    local reset = math.floor(ngx.now() + retry_after)

    -- 429: pass all required headers to exit at once, not relying on residual set_header state
    local headers = {
      ["Content-Type"] = "application/json; charset=utf-8",
      ["Retry-After"]  = tostring(retry_after),
    }
    if not conf.hide_client_headers then
      headers["X-RateLimit-Limit"]     = tostring(shown_limit)
      headers["X-RateLimit-Remaining"] = "0"
      headers["X-RateLimit-Reset"]     = tostring(reset)
    end

    -- D5: in multi-rule mode the response body's rule field marks the rejection source (human-readable identifier, not a raw internal index)
    local body = {
      message     = "API rate limit exceeded",
      limit       = shown_limit,
      window      = decision.reject_cap and conf.rules[decision.reject_primary].window or conf.window,
      retry_after = retry_after,
    }
    if decision.reject_rules then
      body.rule = decision.reject_rules
    end

    return kong.response.exit(429, body, headers)
  end

  if not conf.hide_client_headers then
    kong.response.set_header("X-RateLimit-Limit", tostring(shown_limit))
    kong.response.set_header("X-RateLimit-Remaining", tostring(decision.remaining))
    kong.response.set_header("X-RateLimit-Reset", tostring(decision.reset))
  end

  return
end

return _M
