-- ============================================================
-- rate-limit-advanced / lib/algorithm.lua
-- Rate limiting main flow: build key → consume the local lease pool → if insufficient, fetch a batch from Redis → decide
--
-- This module is "the single code path": batch=1 means strict global consistency,
-- batch=N means one Redis call per N requests. There is no second implementation.
-- ============================================================
local bit = require "bit"

local redis_mod = require "kong.plugins.rate-limit-advanced.lib.redis"
local lease = require "kong.plugins.rate-limit-advanced.lib.lease"
local keys_mod = require "kong.plugins.rate-limit-advanced.lib.keys"

local _M = {}

-- V1 fixed lease TTL (design D4/D9): manages only Redis lease metadata expiry,
-- unrelated to bucket TTL / returns (V1 has no RETURN). Set to 1h:
--   covers the slowest local consumption window within the tested scope (limit=100/window=3600/batch=20 ⇒ ~720s to drain a batch),
--   while giving leftover records of crashed workers a bounded lifetime, preventing unbounded accumulation.
-- After Phase 5 introduces RETURN/max_lifetime, this constant returns to configuration management.
local LEASE_TTL_MS = 3600000

local MAX_DIM_VALUE_LEN = 256

-- FNV-1a 32-bit: h = (h ^ byte) * 16777619 mod 2^32 (P0-1/D1).
-- Lua numbers are doubles; h * 16777619 would exceed 53-bit precision, so the multiply is split into 16-bit halves for exactness.
local function fnv1a32(s)
  local h = 2166136261 -- 0x811c9dc5
  for i = 1, #s do
    h = bit.bxor(h, string.byte(s, i))
    local lo = bit.band(h, 0xffff)
    local hi = bit.rshift(h, 16)
    h = bit.band(lo * 16777619 + bit.band(hi * 16777619, 0xffff) * 0x10000, 0xffffffff)
  end
  -- LuaJIT's bit.band returns a signed 32-bit result; normalize to unsigned,
  -- otherwise %08x sign-extends to 16 bits (e.g. ffffffff8039753e).
  return h % 0x100000000
end

--- Policy fingerprint input string (D1): limit, window, parsed burst, limit_by order,
-- header_name (only when limit_by contains header). batch is excluded: batch is a transport parameter,
-- it does not change the bucket identity; including it would wipe the whole bucket whenever batch is tuned.
local function fingerprint_input(conf)
  local _, burst = _M.rate_and_burst(conf)
  local segs = {
    "limit=" .. tostring(conf.limit),
    "window=" .. tostring(conf.window),
    "burst=" .. tostring(burst),
    "limit_by=" .. table.concat(conf.limit_by, ","),
  }
  for i = 1, #conf.limit_by do
    if conf.limit_by[i] == "header" then
      segs[#segs + 1] = "header_name=" .. tostring(conf.header_name or "")
      break
    end
  end
  return table.concat(segs, ";")
end

--- Policy fingerprint (P0-1, D1). Pure function: no kong.* dependency, unit-testable directly under resty.
-- @return an 8-char lowercase hex string
function _M.policy_fingerprint(conf)
  return string.format("%08x", fnv1a32(fingerprint_input(conf)))
end

local function dim_value(dim, conf)
  if dim == "consumer" then
    local consumer = kong.client.get_consumer()
    return consumer and consumer.id or "anon"

  elseif dim == "ip" then
    -- get_forwarded_ip() = client address after realip processing: upstream forwarded headers are trusted
    -- only when Kong is configured with trusted_ips; by default (trust none) it is the direct peer IP, spoofed XFF has no effect.
    -- The fallback must be get_ip(), which actually exists in the PDK (direct peer, cannot be spoofed).
    return kong.client.get_forwarded_ip() or kong.client.get_ip() or "unknown"

  elseif dim == "path" then
    return kong.request.get_path() or "/"

  elseif dim == "method" then
    return kong.request.get_method() or "GET"

  elseif dim == "header" then
    local v = kong.request.get_header(conf.header_name)
    if v == nil then
      return "-"
    end
    if #v > MAX_DIM_VALUE_LEN then
      return string.sub(v, 1, MAX_DIM_VALUE_LEN)
    end
    return v

  elseif dim == "route" then
    local route = kong.router.get_route()
    return route and route.id or "-"

  elseif dim == "service" then
    local service = kong.router.get_service()
    return service and service.id or "-"
  end

  return "-"
end

--- Build the Redis key.
-- Shaped like: kong:rl:{rl:p=1a2b3c4d:ip=10.0.0.7:path=/a%3Ab}
-- (':' '{' '}' '%' in dimension values are escaped via encode_value; other characters incl. '/' pass through)
-- The braces are the Redis Cluster hash tag, guaranteeing the same logical key lands in the same slot;
-- p= policy fingerprint (P0-1): any limiting-parameter change yields a new key/new bucket, old buckets and old local lease pools expire naturally via TTL.
-- Dimension values are unambiguously encoded via keys.encode_value (':' '{' '}' '%' escaped; Gate 4 task A):
-- no collisions across multi-dimension combos, stable keys for the same input, dimension values cannot break the hash tag structure.
function _M.build_key(conf)
  -- D2/4.3: runtime fallback validation for rules mode (double insurance with the schema entity_check —
  -- guards against config injection bypassing Admin API validation: validation fails → nil → handler 500 misconfigured)
  if conf.rules and #conf.rules > 0 then
    local rerr = _M.validate_rules(conf)
    if rerr then
      return nil, rerr
    end
    -- Multi-rule mode: return the group key of r1 (primary log key); the full key set is built by check_multi
    local keys, gerr = _M.build_group_keys(conf)
    if not keys then
      return nil, gerr
    end
    return keys[1]
  end

  local parts = {}

  for i = 1, #conf.limit_by do
    local dim = conf.limit_by[i]

    if dim == "header" and (conf.header_name == nil or conf.header_name == "") then
      return nil, "limit_by contains 'header' but header_name is not set"
    end

    parts[i] = dim .. "=" .. keys_mod.encode_value(dim_value(dim, conf))
  end

  local tag = conf.namespace
    .. ":p=" .. _M.policy_fingerprint(conf)
    .. ":" .. table.concat(parts, ":")
  return conf.redis.key_prefix .. ":{" .. tag .. "}"
end

--- Runtime fallback validation for rules mode (D2/4.3, pure function, unit-testable under resty).
-- The schema rejects bad configs upfront (400); this is the second gate for conf injected bypassing the schema.
-- @return nil (valid) or an err string
function _M.validate_rules(conf)
  if #conf.rules > 8 then
    return "rules exceeds max of 8 rules"
  end
  if (conf.batch or 0) > 1 then
    return "batch must be 0 or 1 when rules is set (alpha strict mode has no local lease)"
  end
  for i = 1, #conf.rules do
    local rule = conf.rules[i]
    local dims = rule.limit_by or {}
    for j = 1, #dims do
      if dims[j] == "header" and (rule.header_name == nil or rule.header_name == "") then
        return "rules[" .. i .. "] limit_by contains 'header' but header_name is not set"
      end
    end
  end
  return nil
end

--- The actual batch value. 0 = auto.
-- Formula: clamp(floor(limit / 50), 1, 50)
-- Meaning: tolerates 2% of tokens stranded per node, capped at 50 per fetch to avoid burst amplification.
function _M.resolve_batch(conf)
  if conf.batch and conf.batch > 0 then
    return conf.batch
  end

  local k = math.floor(conf.limit / 50)
  if k < 1 then
    k = 1
  end
  if k > 50 then
    k = 50
  end
  return k
end

--- Derive token bucket parameters from limit/window
function _M.rate_and_burst(conf)
  local rate = conf.limit / conf.window
  local burst = conf.burst
  if not burst or burst <= 0 then
    burst = conf.limit
  end
  return rate, burst
end

--- Token bucket parameters for a single rule (D3: bucket structure keeps tokens/ts; refill formula mirrors the single bucket)
function _M.rule_rate_and_burst(rule)
  local rate = rule.limit / rule.window
  local burst = rule.burst
  if not burst or burst <= 0 then
    burst = rule.limit
  end
  return rate, burst
end

-- D3: group fingerprint input string — all rule parameters concatenated in order.
-- Any rule's limit/window/burst/limit_by/header_name changes ⇒ group fingerprint changes ⇒ the whole group gets new buckets
-- (cost: changing one rule = resetting the whole group's quota; header_name participates only when the corresponding rule uses the header dimension,
--  consistent with the single-rule fingerprint convention, avoiding resets from unrelated field changes).
local function group_fingerprint_input(conf)
  local segs = {}
  for i = 1, #conf.rules do
    local rule = conf.rules[i]
    local _, burst = _M.rule_rate_and_burst(rule)
    local s = "limit=" .. tostring(rule.limit)
      .. ";window=" .. tostring(rule.window)
      .. ";burst=" .. tostring(burst)
      .. ";limit_by=" .. table.concat(rule.limit_by, ",")
    for j = 1, #rule.limit_by do
      if rule.limit_by[j] == "header" then
        s = s .. ";header_name=" .. tostring(rule.header_name or "")
        break
      end
    end
    segs[#segs + 1] = "r" .. i .. "{" .. s .. "}"
  end
  return table.concat(segs, ";")
end

--- D3: group key construction.
-- Shaped like kong:rl:{<ns>:g=<group fingerprint>:r<i>:<dim>=<val>:…}
-- All buckets in a group share the hash tag ⇒ same Redis Cluster slot (hard Cluster prerequisite for multi-key EVAL).
-- @return keys, rates, bursts, ttls_ms, rule_descs
--         or nil, err (some rule's limit_by contains header but header_name is missing)
function _M.build_group_keys(conf)
  local fp = string.format("%08x", fnv1a32(group_fingerprint_input(conf)))
  local keys, rates, bursts, ttls, descs = {}, {}, {}, {}, {}
  for i = 1, #conf.rules do
    local rule = conf.rules[i]
    local parts = {}
    for j = 1, #rule.limit_by do
      local dim = rule.limit_by[j]
      if dim == "header" and (rule.header_name == nil or rule.header_name == "") then
        return nil, "rules[" .. i .. "] limit_by contains 'header' but header_name is not set"
      end
      parts[j] = dim .. "=" .. keys_mod.encode_value(dim_value(dim, rule))
    end
    local rate, burst = _M.rule_rate_and_burst(rule)
    local tag = conf.namespace
      .. ":g=" .. fp
      .. ":r" .. i
      .. ":" .. table.concat(parts, ":")
    keys[i] = conf.redis.key_prefix .. ":{" .. tag .. "}"
    rates[i] = rate
    bursts[i] = burst
    ttls[i] = math.max(1, math.floor(rule.window * 2)) * 1000
    descs[i] = "rules[" .. i .. "]:" .. table.concat(rule.limit_by, "+")
  end
  return keys, rates, bursts, ttls, descs
end

--- D1: multi-rule α strict-consistency decision (one multi-key atomic Lua call per request, no local lease pool).
-- All-or-nothing semantics are enforced server-side within a single Redis script (D4); this only assembles the decision.
-- Response convention (D5):
--   allowed: remaining = min(remaining of all buckets) (bottleneck rule), reset = next-token time of the bottleneck bucket
--   429: retry_after = max(wait of insufficient buckets), cap = max window of insufficient buckets,
--        reject_rules = human-readable identifiers of insufficient rules, reject_primary = index of the rule determining Retry-After
-- @return decision table or nil, err
function _M.check_multi(conf)
  local now = ngx.now()
  local keys, rates, bursts, ttls, descs = _M.build_group_keys(conf)
  if not keys then
    return nil, rates
  end

  local parsed, err = redis_mod.grant_multi(conf, keys, rates, bursts, ttls)
  if not parsed then
    kong.log.err("rate-limit-advanced: redis grant_multi failed: ", tostring(err))
    return nil, err
  end

  if parsed.ok == 1 then
    -- Bottleneck rule = the bucket with the fewest remaining tokens after deduction; Reset = next-token time of the bottleneck bucket (wait=0 means now)
    local min_tokens, min_i = math.huge, 1
    for i = 1, #parsed.buckets do
      local b = parsed.buckets[i]
      if b.tokens < min_tokens then
        min_tokens, min_i = b.tokens, i
      end
    end
    kong.log.debug(
      "[RL-DEBUG] multi_grant keys=", table.concat(keys, " | "),
      " remaining=", min_tokens, " bottleneck=r", min_i
    )
    return {
      allowed            = true,
      remaining          = math.max(0, math.floor(min_tokens)),
      reset              = math.floor(now + (parsed.buckets[min_i].wait or 0)),
      bottleneck         = min_i,
      multi_limit        = conf.rules[min_i].limit,
    }
  end

  -- ok=0: nothing deducted. Retry-After takes max(wait) (cap = max window of insufficient rules),
  -- reject_primary = the rule holding that max (its limit/window determine the 429 header convention).
  local max_wait, primary, cap = -1, 1, 1
  local rule_descs = {}
  for _, rj in ipairs(parsed.rejects) do
    if rj.wait > max_wait then
      max_wait, primary = rj.wait, rj.rule
    end
    local w = conf.rules[rj.rule].window
    if w > cap then
      cap = w
    end
    rule_descs[#rule_descs + 1] = descs[rj.rule]
  end
  kong.log.debug(
    "[RL-DEBUG] multi_reject keys=", table.concat(keys, " | "),
    " reject=", table.concat(rule_descs, ","), " wait=", max_wait
  )
  return {
    allowed       = false,
    remaining     = 0,
    retry_after   = max_wait,
    reject_rules  = table.concat(rule_descs, ","),
    reject_primary = primary,
    reject_cap    = cap,
    multi_limit   = conf.rules[primary].limit,
  }
end

--- D2/D4/D7: lease decision for single-rule batch>1 (Phase 6 wiring).
-- pool_key = the existing bucket key (policy fingerprint + dimension values, D7) ⇒ the local lease pool maps one-to-one to the Redis bucket,
-- config changes naturally isolate old pools via fingerprint changes.
-- Flow: local TAKE (non-yield atomic) → allow if the pool has stock;
--       NEED_GRANT ⇒ GRANT_LEASE (D4 four-way classification):
--         explicitly granted  ⇒ register the lease (done inside lease.grant) → this request then TAKEs exactly 1 token
--         granted=0           ⇒ 429 (existing Retry-After semantics, wait passed through)
--         explicit error      ⇒ nil, err (LEASE_EXISTS / INVALID_ARGUMENT / script load failure)
--         uncertain           ⇒ nil, err (no retry, no registration, losses allowed — frozen decision)
-- V1 scope: no scanner, no RETURN, no automatic return; exhausted leases are removed as CLOSED inside lease.take.
-- @return decision table or nil, err (err is a string, following the handler's existing fault branch)
function _M.check_lease(conf, key)
  local now      = ngx.now()
  local ttl_s    = math.max(1, math.floor(conf.window * 2))
  local ttl_ms   = ttl_s * 1000
  local rate, burst = _M.rate_and_burst(conf)
  local batch    = _M.resolve_batch(conf)
  -- When the fast path has no local stock, "next-token time" can only be approximated: one refill period of window/limit seconds
  local next_tick = math.ceil(1 / rate)

  -- 1) fast path: worker-local TAKE, zero network IO
  local tok, remaining = lease.take(key)
  if tok then
    kong.log.debug(
    "[RL-DEBUG] local_hit key=", key,
    " remaining=", remaining
    )
    local reset
    if remaining > 0 then
      reset = math.floor(now)          -- next token already available
    else
      reset = math.floor(now + next_tick) -- took the last one just now, conservative approximation
    end
    return {
      allowed   = true,
      remaining = math.max(0, remaining),
      reset     = reset,
    }
  end

  -- 2) No local stock ⇒ two kinds of degraded-mode checks before GRANT (Gate 2 frozen: plan B / MAX_POOLS):
  --    * MAX_POOLS at the cap with no evictable empty pool ⇒ do not evict ACTIVE pools; this request
  --      degrades to a batch=1 direct call that registers no local lease pool (no 429 / no 503; aggressive high-cardinality
  --      traffic cannot push normal users into rejection);
  --    * The pool already has an in-flight GRANT ⇒ concurrent requests also take the batch=1 direct path (no registration),
  --      guaranteeing at most 1 active lease per pool.
  --    The direct path reuses the existing batch=1 semantics (429/Fail-close) and stays out of lease accounting.
  local capacity_ok = lease.ensure_capacity()
  local direct_reason
  if not capacity_ok then
    direct_reason = "pool_cap"
  elseif lease.grant_in_flight(key) then
    direct_reason = "inflight"
  end
  if direct_reason then
    local granted, derr = redis_mod.grant(conf, key, 1, ttl_ms, rate, burst)
    if not granted then
      kong.log.err("rate-limit-advanced: direct degrade grant failed (",
                   direct_reason, "): ", tostring(derr))
      return nil, derr
    end
    if granted.granted <= 0 then
      local wait = granted.wait
      if not wait or wait <= 0 then
        wait = 1
      end
      return {
        allowed     = false,
        remaining   = 0,
        retry_after = wait,
      }
    end
    if direct_reason == "pool_cap" then
      kong.log.warn("rate-limit-advanced: pool_cap_degraded reason=pool_cap key=", key)
    else
      kong.log.debug("rate-limit-advanced: inflight_degraded key=", key)
    end
    return {
      allowed   = true,
      remaining = math.max(0, granted.granted - 1),
      reset     = math.floor(now + (granted.wait or 0)),
    }
  end

  -- 3) Normal GRANT_LEASE request for a new lease (D4 four-way classification)
  local res, gerr = lease.grant(conf, key, key, batch, LEASE_TTL_MS,
                                rate, burst, ttl_ms)
  if not res then
    -- explicit_error and uncertain both enter the existing fault branch (Fail-close):
    -- an explicit error is guaranteed zero-write, an uncertain result may already have executed — neither may be disguised as a 429
    kong.log.err("rate-limit-advanced: lease grant failed (",
                 tostring(gerr.kind), "): ", tostring(gerr.err))
    return nil, gerr.err
  end
  kong.log.debug(
  "[RL-DEBUG] lease_grant key=", key,
  " lease_id=", res.lease_id,
  " granted=", res.granted,
  " wait=", res.wait
  )

  -- 4) Explicitly insufficient (granted=0, fewer than 1 token in the bucket) ⇒ 429 (existing semantics, no lease created)
  if res.ok == false then
    local wait = res.wait
    if not wait or wait <= 0 then
      wait = 1
    end
    return {
      allowed     = false,
      remaining   = 0,
      retry_after = wait,
    }
  end

  -- 5) Explicitly granted (granted>=1, lease registered) ⇒ this request must consume exactly 1 token,
  --    it may not register the stock yet skip the current request (granted>=1 ⇒ active is non-empty ⇒ TAKE must succeed;
  --    the defensive branch is treated as a fault; never allow unauthorized stock)
  local tok2, remaining2 = lease.take(key)
  if not tok2 then
    kong.log.err("rate-limit-advanced: lease take after grant returned NEED_GRANT: ",
                 tostring(key))
    return nil, "lease take after grant returned NEED_GRANT"
  end
  kong.log.debug(
  "[RL-DEBUG] lease_take_after_grant key=", key,
  " remaining=", remaining2
  )

  -- slow path allowed: wait=0 ⇒ next token already available; wait>0 ⇒ tokens<1 in the bucket after partial grant
  return {
    allowed   = true,
    remaining = math.max(0, remaining2),
    reset     = math.floor(now + (res.wait or 0)),
  }
end

--- Core decision.
-- remaining convention (consistent across fast/slow paths): always "remaining from this node's perspective" —
-- fast path is the local lease pool balance; slow path's granted-1 exactly equals the local stock after fill.
-- Reset convention (D1): "the Unix second when the next token becomes available"; on the 429 path the handler derives it
-- from the capped Retry-After (same convention), so reset is not returned here.
-- @return table {allowed, remaining, reset, retry_after} or nil, err
function _M.check(conf, key)
  -- D1: multi-rule mode takes the α strict-consistency branch (no local lease pool, one multi-key atomic Lua per request)
  if conf.rules and #conf.rules > 0 then
    return _M.check_multi(conf)
  end

  local now      = ngx.now()
  local ttl_s    = math.max(1, math.floor(conf.window * 2))
  local ttl_ms   = ttl_s * 1000
  local rate, burst = _M.rate_and_burst(conf)
  -- When the fast path has no local stock, "next-token time" can only be approximated: one refill period of window/limit seconds
  local next_tick = math.ceil(1 / rate)

  -- batch resolved first: batch=1 = strict global consistency mode, bypassing the local lease pool entirely (D4)
  local batch = _M.resolve_batch(conf)

  -- 1) Lease path: single-rule batch>1 ⇒ worker-local TAKE / GRANT_LEASE (Phase 6)
  if batch > 1 then
    return _M.check_lease(conf, key)
  end

  -- 2) slow path: fetch a batch from the global bucket (with batch=1 every request goes through this path)

  local granted, err = redis_mod.grant(conf, key, batch, ttl_ms, rate, burst)
  if not granted then
    -- rule.md §9.1 question A: must check for nil before dereferencing granted.*,
    -- otherwise a Redis failure raises a Lua exception here (500) and the fault_tolerant branch is never reached.
    kong.log.err("rate-limit-advanced: redis grant failed: ", tostring(err))
    return nil, err
  end
  kong.log.debug(
  "[RL-DEBUG] redis_grant key=", key,
  " granted=", granted.granted,
  " tokens=", granted.tokens,
  " wait=", granted.wait
  )

  if granted.granted <= 0 then
    local wait = granted.wait
    if not wait or wait <= 0 then
      wait = 1
    end
    -- The 429 Reset is derived by the handler from the capped Retry-After (same convention), reset is not returned here
    return {
      allowed     = false,
      remaining   = 0,
      retry_after = wait,
    }
  end
  -- batch=1: this request consumes exactly 1 of granted=1, no local lease pool (batch>1 already routed to check_lease above)

  -- slow path allowed: wait=0 ⇒ next token already available; wait>0 ⇒ tokens<1 in the bucket after partial grant
  return {
    allowed   = true,
    remaining = granted.granted - 1,
    reset     = math.floor(now + (granted.wait or 0)),
  }
end

return _M
