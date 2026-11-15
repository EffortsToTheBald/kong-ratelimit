-- ============================================================
-- rate-limit-advanced / lib/lease.lua
-- Worker-local lease manager (Gate 3 remediation: pool lifecycle + expiry + accounting).
-- Design basis: docs/REMEDIATION.md Gate 2 frozen version (e0c3cf1).
--
-- Ownership model (unchanged):
--   * one copy of module state per worker (OpenResty has an independent Lua VM per worker).
--   * TAKE / removal / registration / counting all happen in synchronous sections with no yield points.
--   * Uncertain GRANT result ⇒ no retry, no local lease pool registration (D4, unchanged).
--
-- Gate 3 additions (frozen design implemented item by item):
--   * Pool lifecycle: created by register; recycled by the Timer when active is empty and idle beyond max_age;
--     under MAX_POOLS pressure only pools without ACTIVE leases are evicted (zero inventory loss).
--   * Expiry: created_at + pool.max_age/1000 < ngx.now() (seconds/milliseconds convention) ⇒ EXPIRED,
--     remaining is counted into discarded_tokens (the sole source), not returned to Redis.
--   * TAKE expiry check: O(1) comparison per candidate, removed immediately if expired; under plan B #active ≤ 1
--     ⇒ worst-case scan is strictly O(1).
--   * Single removal function expire_lease: shared by the three paths TAKE / GRANT sweep / Timer,
--     counting logic exists only once ⇒ discarded is never double-counted.
--   * Single in-flight GRANT: _inflight[pool_key] flag; concurrent GRANTs while it is set are
--     degraded to a batch=1 direct call by the algorithm layer (no registration).
--   * Accounting identity: confirmed_granted = consumed + outstanding + discarded
--     (tokens_granted == tokens_consumed + Σactive.remaining + discarded_tokens).
-- ============================================================
local ngx_now = ngx.now
local ngx_worker_id = ngx.worker.id

local redis_mod = require "kong.plugins.rate-limit-advanced.lib.redis"

local _M = {}

-- ------------------------------------------------------------
-- Worker-level state
--   pools[pool_key] = { active = {lease_obj,...}   consumable set (≤1 under plan B)
--                       last_used = seconds        assigned once on TAKE/registration
--                       max_age  = milliseconds    config snapshot of the first GRANT (=2×window)}
--   lease_obj = { lease_id, pool_key, granted, remaining, consumed,
--                 created_at(seconds), state }  -- ACTIVE | CLOSED | EXPIRED
--   inflight[pool_key] = true                    single in-flight GRANT flag
--   Terminal-state objects (CLOSED/EXPIRED) are unreferenced immediately and reclaimed by GC; history lives in counters.
--   Invariants: remaining + consumed = granted; 0 ≤ remaining ≤ granted;
--           each object appears in active at most once; #active ≤ 1 (plan B upper bound).
-- ------------------------------------------------------------
_M._pools = {}
_M._inflight = {}
_M._pool_count = 0

-- MAX_POOLS: per-worker pool count cap (Gate 2 frozen: 10000; overridable in tests)
_M.MAX_POOLS = 10000

-- In-process lifecycle counters (historical stats; the numbers themselves are bounded)
_M._counters = {
  leases = 0, tokens_granted = 0, tokens_consumed = 0, closed = 0,
  expired = 0, evicted = 0, discarded_tokens = 0,
}

-- Per-call cap for GRANT-path lazy sweep / Timer processing (frozen: 32 / 64)
local SWEEP_CAP = 32
local TIMER_POOL_CAP = 64

-- ------------------------------------------------------------
-- lease_id generation (unchanged)
-- ------------------------------------------------------------
local lease_seq = 0

local function host_name()
  local ok, v = pcall(function() return ngx.var.hostname end)
  if ok and type(v) == "string" and v ~= "" then
    return v
  end
  return os.getenv("HOSTNAME") or "unknown"
end

local cached_host
local seeded = false
local function ensure_random_seed()
  if seeded then
    return
  end
  local pid = 0
  pcall(function() pid = ngx.worker.pid() or 0 end)
  math.randomseed(math.floor(ngx_now() * 1000) + pid)
  seeded = true
end

function _M.new_lease_id()
  if not cached_host then
    cached_host = host_name()
  end
  ensure_random_seed()
  lease_seq = lease_seq + 1
  return string.format("%s:%s:%d:%06x",
    cached_host,
    tostring(ngx_worker_id and ngx_worker_id() or 0),
    lease_seq,
    math.random(0, 0xffffff))
end

-- ------------------------------------------------------------
-- Expiry check and removal (sole entry point; non-yield section)
-- Unit convention (frozen): created_at / ngx.now() in seconds; pool.max_age in milliseconds.
-- ------------------------------------------------------------
local function is_expired(l, pool, now)
  return pool.max_age ~= nil
     and (l.created_at + pool.max_age / 1000) < now
end

-- Guarantee that discarded is counted exactly once: state flips first, then removal from active, counting in the same section.
-- Removal on any path (TAKE / GRANT sweep / Timer) must go through this function.
local function expire_lease_at(pool, i)
  local l = pool.active[i]
  l.state = "EXPIRED"
  _M._counters.discarded_tokens = _M._counters.discarded_tokens + l.remaining
  _M._counters.expired = _M._counters.expired + 1
  table.remove(pool.active, i)
end

-- ------------------------------------------------------------
-- Register an already granted lease.
-- Plan B upper bound: the pool already has an ACTIVE lease ⇒ reject (unreachable on the production path;
-- if triggered it means the in-flight gate failed; treated as an uncertain loss, conservative direction).
-- max_age_ms: config snapshot of the pool's first GRANT (= 2×window ms); effective only the first time.
-- @return lease object, or nil, err (invalid arguments / pool busy)
-- ------------------------------------------------------------
function _M.register(pool_key, lease_id, granted, created_at, max_age_ms)
  if type(pool_key) ~= "string" or pool_key == "" then
    return nil, "pool_key required"
  end
  if type(lease_id) ~= "string" or lease_id == "" then
    return nil, "lease_id required"
  end
  if type(granted) ~= "number"
     or granted ~= math.floor(granted)
     or granted < 1 or granted >= 2^53 then
    return nil, "granted must be a positive integer: " .. tostring(granted)
  end

  local pool = _M._pools[pool_key]
  if pool and #pool.active > 0 then
    return nil, "pool has active lease: " .. pool_key
  end
  if not pool then
    pool = { active = {}, last_used = nil, max_age = nil }
    _M._pools[pool_key] = pool
    _M._pool_count = _M._pool_count + 1
  end
  if pool.max_age == nil and max_age_ms ~= nil then
    if type(max_age_ms) ~= "number" or max_age_ms ~= max_age_ms
       or max_age_ms <= 0 or max_age_ms >= 2^53 then
      return nil, "max_age_ms must be a positive number: " .. tostring(max_age_ms)
    end
    pool.max_age = max_age_ms
  end

  local lease = {
    lease_id   = lease_id,
    pool_key   = pool_key,
    granted    = granted,
    remaining  = granted,          -- remaining + consumed = granted (conservation starting point)
    consumed   = 0,
    created_at = created_at or ngx_now(),
    state      = "ACTIVE",
  }
  pool.active[#pool.active + 1] = lease
  pool.last_used = lease.created_at
  _M._counters.leases = _M._counters.leases + 1
  _M._counters.tokens_granted = _M._counters.tokens_granted + granted
  return lease
end

-- ------------------------------------------------------------
-- TAKE: atomically consume 1 token from the local lease pool.
-- The whole function is a non-yield synchronous section: ngx.now() is not a yield point; no cosocket / ngx.sleep.
-- Hot path: one assignment to last_used + an expiry comparison for at most 1 candidate (plan B upper bound ⇒ strictly O(1)).
-- Candidate expired ⇒ removed by expire_lease_at (discarded counted once) and continue; no candidate ⇒ NEED_GRANT.
-- @return true, remaining(after deduction), lease_id | false, "NEED_GRANT"
-- ------------------------------------------------------------
function _M.take(pool_key)
  local pool = _M._pools[pool_key]
  if not pool then
    return false, "NEED_GRANT"
  end

  local now = ngx_now()
  pool.last_used = now             -- the sole write point across the TAKE path (single assignment)
  local active = pool.active
  local i = 1
  while i <= #active do
    local l = active[i]
    if l.state ~= "ACTIVE" then
      table.remove(active, i)      -- defensive: non-ACTIVE should never appear inside the active set
    elseif is_expired(l, pool, now) then
      expire_lease_at(pool, i)
    else
      l.remaining = l.remaining - 1
      l.consumed = l.consumed + 1
      _M._counters.tokens_consumed = _M._counters.tokens_consumed + 1
      if l.remaining == 0 then
        l.state = "CLOSED"
        table.remove(active, i)
        _M._counters.closed = _M._counters.closed + 1
      end
      return true, l.remaining, l.lease_id
    end
  end
  return false, "NEED_GRANT"
end

-- ------------------------------------------------------------
-- GRANT result classification (unchanged, D4 four-way classification; pure function).
-- ------------------------------------------------------------
local EXPLICIT_ERR_MARKS = {
  "LEASE_EXISTS",
  "INVALID_ARGUMENT",
  "script load failed",
  "script still missing after reload",
}

local function is_explicit_grant_err(err)
  if type(err) ~= "string" then
    return false
  end
  for i = 1, #EXPLICIT_ERR_MARKS do
    if string.find(err, EXPLICIT_ERR_MARKS[i], 1, true) then
      return true
    end
  end
  return false
end

function _M.classify_grant(parsed, err)
  if parsed ~= nil then
    if type(parsed) ~= "table" or parsed.granted == nil
       or parsed.granted < 0 then
      return "uncertain", err or "malformed grant_lease response"
    end
    if parsed.granted >= 1 then
      return "success", parsed
    end
    return "insufficient", parsed
  end
  if is_explicit_grant_err(err) then
    return "explicit_error", err
  end
  return "uncertain", err
end

-- ------------------------------------------------------------
-- GRANT-path lazy sweep: remove expired leases in the current pool (cap 32 per call).
-- Executed by grant() before the transport call; pure table operations, non-yield.
-- ------------------------------------------------------------
function _M.sweep_pool(pool_key, cap)
  local pool = _M._pools[pool_key]
  if not pool then
    return 0
  end
  cap = cap or SWEEP_CAP
  local now = ngx_now()
  local removed = 0
  local i = 1
  while i <= #pool.active and removed < cap do
    local l = pool.active[i]
    if l.state ~= "ACTIVE" then
      table.remove(pool.active, i)
    elseif is_expired(l, pool, now) then
      expire_lease_at(pool, i)
      removed = removed + 1
    else
      i = i + 1
    end
  end
  return removed
end

-- ------------------------------------------------------------
-- Single in-flight GRANT flag (plan B). Set/clear both happen inside grant()'s non-yield sections:
-- the algorithm layer checks grant_in_flight() before calling grant() (no yield point between
-- the check and the set ⇒ coroutine scheduling guarantees atomicity), concurrent requests during the in-flight window degrade to the direct path.
-- ------------------------------------------------------------
function _M.grant_in_flight(pool_key)
  return _M._inflight[pool_key] == true
end

-- ------------------------------------------------------------
-- Request a lease.
--   * Lazy sweep of the current pool before GRANT (frozen §4).
--   * max_age snapshot = bucket_ttl_ms (= 2×window ms, same source as the bucket TTL).
--   * Uncertain result ⇒ no retry, no registration (D4, unchanged).
-- @return same as the existing four-way classification
-- ------------------------------------------------------------
_M._transport = nil  -- test injection point; nil ⇒ redis_mod.grant_lease

function _M.grant(conf, pool_key, bucket_key, batch, lease_ttl_ms,
                   rate, capacity, bucket_ttl_ms)
  local transport = _M._transport or redis_mod.grant_lease
  local lease_id = _M.new_lease_id()

  _M.sweep_pool(pool_key)
  _M._inflight[pool_key] = true
  local parsed, err = transport(conf, bucket_key, lease_id, pool_key,
                                batch, lease_ttl_ms, rate, capacity, bucket_ttl_ms)
  local class, data = _M.classify_grant(parsed, err)
  _M._inflight[pool_key] = nil     -- no yield point between the clear and classify/register

  if class == "success" then
    local lease, rerr = _M.register(pool_key, lease_id, data.granted, nil, bucket_ttl_ms)
    if not lease then
      return nil, { kind = "uncertain", err = "register failed: " .. tostring(rerr) }
    end
    return {
      ok       = true,
      granted  = data.granted,
      tokens   = data.tokens,
      wait     = data.wait,
      lease_id = lease_id,
      lease    = lease,
    }
  elseif class == "insufficient" then
    return { ok = false, reason = "insufficient", tokens = data.tokens, wait = data.wait }
  else
    return nil, { kind = class, err = data }
  end
end

-- ------------------------------------------------------------
-- Pool capacity (MAX_POOLS, frozen: 10000/worker).
-- In-flight GRANTs occupy pool slots (Gate 3 review fix + re-review correction): a slot is taken only when the pool key
-- **does not yet exist in _pools** (register will create a new pool); an in-flight GRANT for an existing pool
-- reuses that pool (register rejects busy and eviction skips inflight ⇒ the pool
-- survives until register), taking no new slot — otherwise double counting would cause unnecessary capacity degradation.
-- ensure_capacity: below the cap ⇒ true; at the cap ⇒ first evict pools without ACTIVE leases and not
-- in-flight (≤64, zero inventory loss); if still full ⇒ false (the caller degrades to a batch=1 direct call).
-- ------------------------------------------------------------
function _M.pool_count()
  return _M._pool_count
end

local function inflight_count()
  local n = 0
  for key, v in pairs(_M._inflight) do
    if v == true and _M._pools[key] == nil then
      n = n + 1
    end
  end
  return n
end

function _M.ensure_capacity()
  if _M._pool_count + inflight_count() < _M.MAX_POOLS then
    return true
  end
  _M.evict_idle_pools(TIMER_POOL_CAP)
  return _M._pool_count + inflight_count() < _M.MAX_POOLS
end

-- Evict only pools without ACTIVE leases (frozen: never evict pools holding an ACTIVE lease);
-- also skip pools with an in-flight GRANT (Gate 3 review fix: after the GRANT of an inflight pool returns,
-- register rebuilds the pool ⇒ _pool_count would exceed MAX_POOLS).
-- Pure table operations, non-yield; key set scan O(P) bounded by MAX_POOLS.
function _M.evict_idle_pools(cap)
  cap = cap or TIMER_POOL_CAP
  local removed = 0
  for key, pool in pairs(_M._pools) do
    if removed >= cap then
      break
    end
    if _M._inflight[key] ~= true and #pool.active == 0 then
      _M._pools[key] = nil
      _M._pool_count = _M._pool_count - 1
      _M._counters.evicted = _M._counters.evicted + 1
      removed = removed + 1
    end
  end
  return removed
end

-- ------------------------------------------------------------
-- Timer fallback sweep (called by init_worker every 60s; directly callable in unit tests).
-- Only handles "idle candidates": pools whose last_used is ≥ max_age/1000 ago (in seconds);
-- processes ≤ cap pools per tick (frozen 64). For an idle pool: first remove its expired leases
-- (via expire_lease_at, discarded counted once), then delete the whole pool once active is empty.
-- Key set scan O(P) bounded by MAX_POOLS; pure table operations, non-yield.
-- @return number of pools deleted this round
-- ------------------------------------------------------------
function _M.timer_sweep_once(cap)
  cap = cap or TIMER_POOL_CAP
  local now = ngx_now()
  local evicted = 0
  for key, pool in pairs(_M._pools) do
    if evicted >= cap then
      break
    end
    local max_age_s = pool.max_age and pool.max_age / 1000
    if max_age_s then
      local idle_for = now - (pool.last_used or 0)
      if idle_for >= max_age_s and _M._inflight[key] ~= true then
        -- Gate 3 review fix: skip pools with an in-flight GRANT (after the GRANT returns, register
        -- rebuilds the pool ⇒ _pool_count would exceed MAX_POOLS).
        local i = 1
        while i <= #pool.active do
          local l = pool.active[i]
          if l.state ~= "ACTIVE" then
            table.remove(pool.active, i)
          elseif is_expired(l, pool, now) then
            expire_lease_at(pool, i)
          else
            i = i + 1
          end
        end
        if #pool.active == 0 then
          _M._pools[key] = nil
          _M._pool_count = _M._pool_count - 1
          _M._counters.evicted = _M._counters.evicted + 1
          evicted = evicted + 1
        end
      end
    end
  end
  return evicted
end

-- ------------------------------------------------------------
-- init_worker fallback Timer (frozen: 60s interval). Module-level duplicate-registration guard
-- (multiple plugin instances share the same worker VM); resty unit-test environments have no ngx.timer ⇒ skipped.
-- ------------------------------------------------------------
local timer_started = false

function _M.start_sweep_timer()
  if timer_started then
    return true
  end
  timer_started = true
  if not (ngx and ngx.timer and ngx.timer.every) then
    return false, "ngx.timer.every unavailable"
  end
  local ok, err = pcall(ngx.timer.every, 60, function(premature)
    if premature then
      return
    end
    local exiting = false
    pcall(function() exiting = ngx.worker.exiting() end)
    if exiting then
      return
    end
    pcall(_M.timer_sweep_once, TIMER_POOL_CAP)
  end)
  if not ok then
    timer_started = false
    return nil, "timer create failed: " .. tostring(err)
  end
  return true
end

-- ------------------------------------------------------------
-- D8 metrics (remediation convention): outstanding = local_remaining;
-- discarded_tokens is maintained by expire_lease_at; see invariants() for the identity.
-- ------------------------------------------------------------
function _M.stats()
  local active, remaining = 0, 0
  for _, pool in pairs(_M._pools) do
    for i = 1, #pool.active do
      active = active + 1
      remaining = remaining + pool.active[i].remaining
    end
  end
  local c = _M._counters
  return {
    leases           = c.leases,
    granted          = c.tokens_granted,
    consumed         = c.tokens_consumed,
    closed           = c.closed,
    expired          = c.expired,
    evicted          = c.evicted,
    discarded_tokens = c.discarded_tokens,
    active           = active,
    local_remaining  = remaining,
    outstanding      = remaining,
    pools            = _M._pool_count,
  }
end

-- ------------------------------------------------------------
-- Structural invariant checks (remediation convention):
--   * per pool #active ≤ 1 (plan B upper bound)
--   * active objects: state=ACTIVE, 0 < remaining ≤ granted, conservation
--   * global accounting: tokens_granted == tokens_consumed + Σactive.remaining
--               + discarded_tokens
--   * lease count closure: leases == closed + expired + active_total
-- @return true | false, reason
-- ------------------------------------------------------------
function _M.invariants()
  local n_active = 0
  local sum_remaining = 0
  for _, pool in pairs(_M._pools) do
    if #pool.active > 1 then
      return false, "active lease bound broken: " .. tostring(#pool.active)
    end
    local seen = {}
    for i = 1, #pool.active do
      local l = pool.active[i]
      if seen[l] then
        return false, "duplicate object in active set"
      end
      seen[l] = true
      if l.state ~= "ACTIVE" then
        return false, "active contains non-ACTIVE lease: " .. l.lease_id
      end
      if type(l.granted) ~= "number" or l.granted < 1 or l.granted >= 2^53 then
        return false, "granted invalid: " .. tostring(l.granted)
      end
      if type(l.remaining) ~= "number"
         or l.remaining < 0 or l.remaining > l.granted then
        return false, "remaining out of range: " .. tostring(l.remaining)
      end
      if l.remaining + l.consumed ~= l.granted then
        return false, "conservation broken: " .. l.lease_id
      end
      n_active = n_active + 1
      sum_remaining = sum_remaining + l.remaining
    end
  end
  local c = _M._counters
  -- Capacity-cap invariant (Gate 3 review addition): on the production path every register is preceded by
  -- ensure_capacity passing ⇒ count never exceeds MAX_POOLS (tests mutating MAX directly are an artificial state)
  if _M._pool_count > _M.MAX_POOLS then
    return false, "pool count exceeds MAX_POOLS: " .. _M._pool_count
      .. " > " .. _M.MAX_POOLS
  end
  -- Terminal-state objects are released, so the per-object sum only covers active; the global convention is verified via the identity and count closure:
  --   granted = consumed + outstanding + discarded (per-object conservation transfers at removal time)
  if c.tokens_granted ~= c.tokens_consumed + sum_remaining + c.discarded_tokens then
    return false, "accounting identity broken: granted=" .. c.tokens_granted
      .. " consumed=" .. c.tokens_consumed
      .. " outstanding=" .. sum_remaining
      .. " discarded=" .. c.discarded_tokens
  end
  if c.leases ~= c.closed + c.expired + n_active then
    return false, "lease count not closed: leases=" .. c.leases
      .. " closed=" .. c.closed .. " expired=" .. c.expired
      .. " active=" .. n_active
  end
  return true
end

-- ------------------------------------------------------------
-- Reset worker-level state (test-only: equivalent to a worker restart).
-- ------------------------------------------------------------
function _M.reset()
  _M._pools = {}
  _M._inflight = {}
  _M._pool_count = 0
  _M._counters = {
    leases = 0, tokens_granted = 0, tokens_consumed = 0, closed = 0,
    expired = 0, evicted = 0, discarded_tokens = 0,
  }
  lease_seq = 0
end

return _M
