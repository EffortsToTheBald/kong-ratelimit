-- ============================================================
-- rate-limit-advanced / lib/redis.lua
-- Redis connection (keepalive reuse) + embedded token bucket scripts.
--
-- Why embedded scripts instead of reading files:
--   1) the plugin directory is mounted read-only, avoiding runtime IO
--   2) EVAL script text is cached by Redis by SHA, so repeated calls do not re-parse
-- ============================================================
local redis = require "resty.redis"
local keys_mod = require "kong.plugins.rate-limit-advanced.lib.keys"

local _M = {}

-- ------------------------------------------------------------
-- Token bucket (server-side time)
--
-- KEYS[1] bucket key
-- ARGV[1] rate   tokens replenished per second
-- ARGV[2] burst  bucket capacity
-- ARGV[3] want   how many tokens to fetch this time
-- ARGV[4] ttl    expiry (milliseconds)
--
-- Returns { granted(integer), tokens(string), wait(string) }
--
-- Notes:
--   * TIME uses Redis's own clock, eliminating clock drift across gateway nodes
--   * floats must be returned via tostring, otherwise Redis truncates numbers to integers
-- ------------------------------------------------------------
local TOKEN_BUCKET = [[
local key   = KEYS[1]
local rate  = tonumber(ARGV[1])
local burst = tonumber(ARGV[2])
local want  = tonumber(ARGV[3])
local ttl   = tonumber(ARGV[4])

local t   = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000

local d      = redis.call('HMGET', key, 'tokens', 'ts')
local tokens = tonumber(d[1])
local ts     = tonumber(d[2])

if tokens == nil then tokens = burst end
if ts == nil then ts = now end

-- P0-4: ts only moves forward. During clock rollback neither refill nor lower ts,
-- otherwise once the clock catches up the same period gets billed twice, minting tokens out of thin air.
if now > ts then
  tokens = tokens + (now - ts) * rate
  if tokens > burst then tokens = burst end
  ts = now
end

local granted = 0
if tokens >= want then
  granted = want
elseif tokens >= 1 then
  granted = math.floor(tokens)
end

tokens = tokens - granted

-- D1: wait is unified as "seconds until the next token is available".
-- When tokens >= 1, (1-tokens) <= 0, clamped to 0 (next token already available);
-- when tokens < 1 it is the wait to replenish one full token.
local wait = 0
if rate > 0 then
  wait = (1 - tokens) / rate
  if wait < 0 then
    wait = 0
  end
end

redis.call('HSET', key, 'tokens', tostring(tokens), 'ts', tostring(ts))
redis.call('PEXPIRE', key, ttl)

return { granted, tostring(tokens), tostring(wait) }
]]

_M.script = TOKEN_BUCKET

-- ------------------------------------------------------------
-- D4: multi-key atomic script (α strict-consistency mode). Dual-source synced with redis/multi_bucket.lua.
--
-- KEYS   = r1..rN per-rule bucket keys (same hash tag within the group ⇒ same slot)
-- ARGV[1]= n, then 3 params per rule: rate burst ttl_ms
-- Returns (flat array):
--   success { 1, tokens_1, wait_1, ..., tokens_n, wait_n } (after deduction)
--   failure { 0, rule index, wait, ... } (insufficient rules, all buckets untouched)
-- Semantics: "check-all then deduct-all-or-nothing" within one script — check and deduction are indivisible, no local rollback window.
-- ------------------------------------------------------------
local GRANT_MULTI = [[
local n = tonumber(ARGV[1])

local t   = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000

-- 1) refill each bucket (same formula as the single-bucket script: monotonic TIME, burst cap, ts only moves forward)
local tokens = {}
local ts = {}
local rate = {}
local burst = {}
local ttl = {}
for i = 1, n do
  rate[i]  = tonumber(ARGV[2 + (i - 1) * 3])
  burst[i] = tonumber(ARGV[3 + (i - 1) * 3])
  ttl[i]   = tonumber(ARGV[4 + (i - 1) * 3])

  local d = redis.call('HMGET', KEYS[i], 'tokens', 'ts')
  local tk  = tonumber(d[1])
  local lts = tonumber(d[2])
  if tk == nil then tk = burst[i] end
  if lts == nil then lts = now end

  -- P0-4: ts only moves forward. During clock rollback neither refill nor lower ts,
  -- otherwise once the clock catches up the same period gets billed twice, minting tokens out of thin air.
  if now > lts then
    tk = tk + (now - lts) * rate[i]
    if tk > burst[i] then tk = burst[i] end
    lts = now
  end

  tokens[i] = tk
  ts[i] = lts
end

-- D1 wait convention: 0 when tokens >= 1 (next token already available); when < 1 the wait to replenish one full token.
local function wait_of(i, tk)
  if rate[i] <= 0 then
    return 0
  end
  local w = (1 - tk) / rate[i]
  if w < 0 then
    return 0
  end
  return w
end

-- 2) full check: deduct only if all buckets have tokens >= 1 after refill
local all_ok = true
for i = 1, n do
  if tokens[i] < 1 then
    all_ok = false
  end
end

if all_ok then
  local out = { 1 }
  for i = 1, n do
    tokens[i] = tokens[i] - 1
    redis.call('HSET', KEYS[i], 'tokens', tostring(tokens[i]), 'ts', tostring(ts[i]))
    redis.call('PEXPIRE', KEYS[i], ttl[i])
    out[#out + 1] = tostring(tokens[i])
    out[#out + 1] = tostring(wait_of(i, tokens[i]))
  end
  return out
end

-- 3) any insufficient → write nothing (deduct no bucket, update no ts), return insufficient rules with their waits
local out = { 0 }
for i = 1, n do
  if tokens[i] < 1 then
    out[#out + 1] = i
    out[#out + 1] = tostring(wait_of(i, tokens[i]))
  end
end
return out
]]
-- ------------------------------------------------------------
-- GRANT_LEASE (Phase 3): lease grant (bucket deduction + lease record creation atomic).
-- KEYS[1]=bucket key KEYS[2]=kong:rl:lease:{lease_id}
-- ARGV=[batch, lease_ttl_ms, lease_id, pool_key, rate, capacity, bucket_ttl_ms]
-- Returns {granted, tokens, wait} or error codes (LEASE_EXISTS/INVALID_ARGUMENT, zero writes).
-- tokens<1 ⇒ granted=0, no record created. See redis/grant_lease.lua for full semantics (dual source).
-- ------------------------------------------------------------
local GRANT_LEASE = [[
local bkey   = KEYS[1]
local lkey   = KEYS[2]
local batch  = tonumber(ARGV[1])
local lease_ttl_ms = tonumber(ARGV[2])
local lease_id     = ARGV[3]
local pool_key     = ARGV[4]
local rate         = tonumber(ARGV[5])
local capacity     = tonumber(ARGV[6])
local bucket_ttl_ms = tonumber(ARGV[7])

-- Finite number check (Lua has no isfinite: NaN is unequal to itself, ±inf compares with huge)
local function is_finite_num(v)
  return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_valid_ttl(v)
  return is_finite_num(v) and v == math.floor(v) and v >= 1 and v < 2^53
end

-- Phase 0: argument validation (zero writes)
if not batch or batch ~= math.floor(batch) or batch < 1 or batch >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT batch')
end
if not is_valid_ttl(lease_ttl_ms) then
  return redis.error_reply('INVALID_ARGUMENT lease_ttl_ms: ' .. tostring(ARGV[2]))
end
if not lease_id or lease_id == '' or not pool_key or pool_key == '' then
  return redis.error_reply('INVALID_ARGUMENT lease_id/pool_key')
end
if not is_finite_num(rate) or rate <= 0
   or not is_finite_num(capacity) or capacity <= 0 or capacity >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT rate/capacity')
end
if not is_valid_ttl(bucket_ttl_ms) then
  return redis.error_reply('INVALID_ARGUMENT bucket_ttl_ms: ' .. tostring(ARGV[7]))
end

-- Phase 1: read-only validation (zero writes) — including bucket state numeric validity (P1-2)
if redis.call('EXISTS', lkey) == 1 then
  return redis.error_reply('LEASE_EXISTS ' .. lease_id)
end
local btype = redis.call('TYPE', bkey).ok
local tokens, ts
if btype == 'none' then
  tokens = capacity   -- new bucket is full (consistent with TOKEN_BUCKET)
  ts = nil
elseif btype == 'hash' then
  local d = redis.call('HMGET', bkey, 'tokens', 'ts')
  if d[1] ~= false and d[1] ~= nil then
    tokens = tonumber(d[1])
    if not is_finite_num(tokens) or tokens < 0 or tokens > capacity then
      return redis.error_reply('INVALID_ARGUMENT bucket tokens: ' .. tostring(d[1]))
    end
  end
  if d[2] ~= false and d[2] ~= nil then
    ts = tonumber(d[2])
    if not is_finite_num(ts) or ts < 0 then
      return redis.error_reply('INVALID_ARGUMENT bucket ts: ' .. tostring(d[2]))
    end
  end
else
  return redis.error_reply('INVALID_ARGUMENT bucket type: ' .. btype)
end

-- Phase 2: refill → grant decision → deduct bucket → create lease (atomic, Redis serializes with no interleaving)
local t   = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
if tokens == nil then tokens = capacity end
local elapsed = 0
if ts ~= nil and now > ts then
  elapsed = now - ts
end
tokens = math.min(capacity, tokens + elapsed * rate)
if elapsed > 0 then
  ts = now
end
-- P0-4: ts only moves forward (no refill and no lowering ts while now<=ts)

local granted = math.min(batch, math.floor(tokens))
-- Order (review P1-1): 1) granted decision 2) deduction 3) wait computed from post-deduction tokens
--   4) write back the bucket 5) return granted/tokens/wait
tokens = tokens - granted
local wait = 0
if rate > 0 then
  wait = math.max(0, (1 - tokens) / rate)
end

-- Bucket state write-back: unified for granted and insufficient branches (consistent with TOKEN_BUCKET, review P1-1 verdict)
if ts == nil or now > ts then ts = now end
redis.call('HSET', bkey, 'tokens', tostring(tokens), 'ts', tostring(ts))
redis.call('PEXPIRE', bkey, bucket_ttl_ms)

if granted < 1 then
  -- tokens < 1: no lease created (bucket state already written back)
  return { 0, tostring(tokens), tostring(wait) }
end

redis.call('HSET', lkey,
  'lease_id', lease_id,
  'pool_key', pool_key,
  'granted', granted,
  'status', 'OPEN',
  'created_at', tostring(now))
redis.call('PEXPIRE', lkey, lease_ttl_ms)

return { granted, tostring(tokens), tostring(wait) }
]]

-- ------------------------------------------------------------
-- RETURN_LEASE (Phase 3): idempotent lease return (commit point first).
-- KEYS[1]=kong:rl:lease:{lease_id} KEYS[2]=bucket key
-- ARGV=[requested, pool_key, bucket_ttl_ms, rate, capacity]
-- Write-order iron rule: write the RETURNED mark first (idempotent commit point), then one HSET with the full bucket state.
-- Returns {requested, applied, discarded} or error codes (all zero writes).
-- See redis/return_lease.lua for full semantics (dual source).
-- ------------------------------------------------------------
local RETURN_LEASE = [[
local lkey  = KEYS[1]
local bkey  = KEYS[2]
local function is_finite_num(v)
  return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end
local function is_valid_ttl(v)
  return is_finite_num(v) and v == math.floor(v) and v >= 1 and v < 2^53
end
local requested = tonumber(ARGV[1])
local pool_key  = ARGV[2]
local bucket_ttl_ms = tonumber(ARGV[3])
local rate      = tonumber(ARGV[4])
local capacity  = tonumber(ARGV[5])

-- Phase 0: argument validation (zero writes)
if not requested or requested ~= math.floor(requested) or requested < 0 or requested >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT requested')
end
if not pool_key or pool_key == '' then
  return redis.error_reply('INVALID_ARGUMENT pool_key')
end
if not is_valid_ttl(bucket_ttl_ms) then
  return redis.error_reply('INVALID_ARGUMENT bucket_ttl_ms: ' .. tostring(ARGV[3]))
end
if not is_finite_num(rate) or rate <= 0
   or not is_finite_num(capacity) or capacity <= 0 or capacity >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT rate/capacity')
end

-- Bucket state numeric validity (review P1-2 verdict, consistent with GRANT_LEASE): tokens ∈ [0, capacity],
--   ts ≥ 0, finite numbers, granted a positive integer <2^53 — invalid states return a clear error code, no silent correction, data unchanged.
-- Phase 1: read-only validation (zero writes)
if redis.call('EXISTS', lkey) == 0 then
  return redis.error_reply('LEASE_NOT_FOUND')
end
local status = redis.call('HGET', lkey, 'status')
if status == 'RETURNED' then
  local rr = redis.call('HGET', lkey, 'return_requested')
  if tonumber(rr) == requested then
    return redis.error_reply('ALREADY_RETURNED')
  end
  return redis.error_reply('RETURN_CONFLICT requested=' .. tostring(requested) .. ' return_requested=' .. tostring(rr))
end
if status ~= 'OPEN' then
  return redis.error_reply('INVALID_LEASE_STATE ' .. tostring(status))
end
local lpk = redis.call('HGET', lkey, 'pool_key')
if lpk ~= pool_key then
  return redis.error_reply('POOL_MISMATCH')
end
local granted = tonumber(redis.call('HGET', lkey, 'granted'))
if not is_finite_num(granted) or granted ~= math.floor(granted)
   or granted < 1 or granted >= 2^53 then
  return redis.error_reply('INVALID_LEASE_STATE granted: ' .. tostring(redis.call('HGET', lkey, 'granted')))
end
if requested > granted then
  return redis.error_reply('INVALID_REQUESTED requested=' .. tostring(requested) .. ' granted=' .. tostring(granted))
end
local btype = redis.call('TYPE', bkey).ok
if btype == 'none' then
  return redis.error_reply('BUCKET_NOT_FOUND')
end
if btype ~= 'hash' then
  return redis.error_reply('INVALID_ARGUMENT bucket type: ' .. btype)
end
local d = redis.call('HMGET', bkey, 'tokens', 'ts')
local btokens, bts
if d[1] ~= false and d[1] ~= nil then
  btokens = tonumber(d[1])
  if not is_finite_num(btokens) or btokens < 0 or btokens > capacity then
    return redis.error_reply('INVALID_ARGUMENT bucket tokens: ' .. tostring(d[1]))
  end
end
if d[2] ~= false and d[2] ~= nil then
  bts = tonumber(d[2])
  if not is_finite_num(bts) or bts < 0 then
    return redis.error_reply('INVALID_ARGUMENT bucket ts: ' .. tostring(d[2]))
  end
end

-- Phase 2: write (after all validations pass)
-- [idempotent commit point] write the RETURNED mark and return_requested first (any later failure ⇒ retry yields ALREADY_RETURNED)
redis.call('HSET', lkey, 'status', 'RETURNED', 'return_requested', requested)

local applied = 0
if requested > 0 then
  local t   = redis.call('TIME')
  local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
  local tokens = btokens
  local ts     = bts
  if tokens == nil then tokens = capacity end   -- hash exists but fields missing (consistent with the grant side: full bucket)
  if ts ~= nil and now > ts then
    tokens = math.min(capacity, tokens + (now - ts) * rate)
    ts = now
  end
  local refilled = tokens
  local new_tokens = math.min(capacity, refilled + requested)
  applied = new_tokens - refilled
  if ts == nil or now > ts then ts = now end
  redis.call('HSET', bkey, 'tokens', tostring(new_tokens), 'ts', tostring(ts))
  redis.call('PEXPIRE', bkey, bucket_ttl_ms)
end
-- requested=0: skip bucket update, still complete OPEN→RETURNED (accounting closes)

-- Lease record TTL is not reset (RETURNED is kept until the original TTL = idempotency protection window)
return { requested, applied, requested - applied }
]]

_M.multi_script = GRANT_MULTI

-- ------------------------------------------------------------
-- EVALSHA unified management (Phase 2):
--   * the script table holds src and SHA; SHA is authoritative from SCRIPT LOAD's return value, cached at worker level
--     (OpenResty has an independent Lua VM per worker, module state is naturally isolated per worker).
--   * the Redis script cache is **instance-level** (under a single-instance deployment, once any connection LOADs,
--     EVALSHA works for all connections on that instance; per-node caching under Cluster is Deferred).
--   * init_worker performs no Redis IO: lazy loading (first call triggers LOAD).
--   * only a "clear NOSCRIPT" triggers LOAD + retry exactly once; timeouts/disconnects/plain errors
--     are always passed through as-is, never treated as NOSCRIPT (preventing double execution of an already-successful deduction).
-- ------------------------------------------------------------
local SCRIPTS = {}

local function register_script(name, src)
    SCRIPTS[name] = { name = name, src = src, sha = nil }
end
register_script("token_bucket", TOKEN_BUCKET)
register_script("grant_multi", GRANT_MULTI)
register_script("grant_lease", GRANT_LEASE)
register_script("return_lease", RETURN_LEASE)
_M.scripts = SCRIPTS

local function is_noscript_err(err)
    return type(err) == "string" and string.find(err, "NOSCRIPT", 1, true) ~= nil
end

local function load_script(r, entry)
    local sha, err = r:script("LOAD", entry.src)
    if not sha or sha == ngx.null then
        return nil, "script load failed: " .. tostring(err)
    end
    entry.sha = sha
    -- NOSCRIPT appears only after script cache loss (FLUSH/restart), very low frequency; warn for auditability
    if kong and kong.log then
        kong.log.warn("rate-limit-advanced: script cache miss (NOSCRIPT), loaded: ", entry.name)
    end
    return sha
end

--- EVALSHA wrapper: lazy load + NOSCRIPT reload-retry exactly once.
-- @return res, err — when err is a clear error the caller takes the existing fault branch
local function evalsha(r, entry, ...)
    if not entry.sha then
        local sha, lerr = load_script(r, entry)
        if not sha then
            return nil, lerr
        end
    end
    local res, err = r:evalsha(entry.sha, ...)
    if not res and is_noscript_err(err) then
        local sha, lerr = load_script(r, entry)
        if not sha then
            return nil, lerr
        end
        res, err = r:evalsha(entry.sha, ...)
        if not res and is_noscript_err(err) then
            return nil, "script still missing after reload: " .. tostring(err)
        end
    end
    return res, err
end
_M.load_script = load_script
_M.evalsha = evalsha

--- D3: defensive validation of the EVAL return value (pure function, no cosocket dependency, directly unit-testable under resty).
-- Valid shape: { granted(integer, 0..want), tokens(number), wait(number, >=0) }.
-- Any violation → nil, reason; the caller (grant) treats it as a Redis error and enters the fault branch.
-- @return table|nil, string|nil
local function parse_grant_response(res, want)
  if type(res) ~= "table" or #res ~= 3 then
    return nil, "malformed eval response: expected 3-element array"
  end

  local granted = tonumber(res[1])
  if granted == nil
     or granted ~= math.floor(granted)
     or granted < 0
     or granted > want then
    return nil, "malformed eval response: granted out of range"
  end

  local tokens = tonumber(res[2])
  if tokens == nil then
    return nil, "malformed eval response: tokens not a number"
  end

  local wait = tonumber(res[3])
  if wait == nil or wait < 0 then
    return nil, "malformed eval response: wait not a number"
  end

  return {
    granted = granted,
    tokens  = tokens,
    wait    = wait,
  }
end
_M.parse_grant_response = parse_grant_response

--- D4: defensive validation of the multi-key script return value (pure function, no cosocket dependency, directly unit-testable under resty).
-- Valid shapes:
--   ok=1: { 1, tokens_1, wait_1, ..., tokens_n, wait_n } (tokens>=0 numbers, wait>=0 numbers)
--   ok=0: { 0, idx, wait, ... } (idx an integer in 1..n without repeats, wait>=0 numbers, at least 1 pair)
-- Any violation → nil, reason; the caller (grant_multi) treats it as a Redis error and enters the fault branch.
-- @return table|nil, string|nil
local function parse_multi_grant_response(n, res)
  if type(res) ~= "table" or #res < 1 then
    return nil, "malformed multi eval response: expected non-empty array"
  end

  local ok = tonumber(res[1])

  if ok == 1 then
    if #res ~= 1 + 2 * n then
      return nil, "malformed multi eval response: expected 1+2n elements for ok=1"
    end
    local buckets = {}
    for i = 1, n do
      local tokens = tonumber(res[2 * i])
      local wait   = tonumber(res[2 * i + 1])
      if tokens == nil or tokens < 0 then
        return nil, "malformed multi eval response: tokens out of range (rule " .. i .. ")"
      end
      if wait == nil or wait < 0 then
        return nil, "malformed multi eval response: wait out of range (rule " .. i .. ")"
      end
      buckets[i] = { tokens = tokens, wait = wait }
    end
    return { ok = 1, buckets = buckets }
  end

  if ok == 0 then
    local rest = #res - 1
    if rest == 0 or rest % 2 ~= 0 then
      return nil, "malformed multi eval response: expected idx/wait pairs for ok=0"
    end
    local rejects = {}
    local seen = {}
    local k = 0
    for p = 2, #res, 2 do
      local idx  = tonumber(res[p])
      local wait = tonumber(res[p + 1])
      if idx == nil or idx ~= math.floor(idx) or idx < 1 or idx > n or seen[idx] then
        return nil, "malformed multi eval response: reject rule index out of range"
      end
      if wait == nil or wait < 0 then
        return nil, "malformed multi eval response: reject wait out of range"
      end
      seen[idx] = true
      k = k + 1
      rejects[k] = { rule = idx, wait = wait }
    end
    return { ok = 0, rejects = rejects }
  end

  return nil, "malformed multi eval response: ok flag not 0/1"
end
_M.parse_multi_grant_response = parse_multi_grant_response

--- Connection setup identical to grant() (kept inline, not extracted into a shared function, so the single-rule path stays untouched).
-- @return r|nil, err|nil (on failure the caller returns directly)
local function connect(conf)
  local r, nerr = redis:new()
  if not r then
    return nil, "cannot create redis client: " .. tostring(nerr)
  end

  local timeout = conf.redis.timeout or 1000
  if r.set_timeouts then
    r:set_timeouts(timeout, timeout, timeout)
  else
    r:set_timeout(timeout)
  end

  local ok, err = r:connect(conf.redis.host, conf.redis.port)
  if not ok then
    return nil, "connect: " .. tostring(err)
  end

  if conf.redis.password and conf.redis.password ~= "" then
    local aok, aerr = r:auth(conf.redis.password)
    if not aok then
      r:close()
      return nil, "auth: " .. tostring(aerr)
    end
  end

  if conf.redis.database and conf.redis.database > 0 then
    local sok, serr = r:select(conf.redis.database)
    if not sok then
      r:close()
      return nil, "select: " .. tostring(serr)
    end
  end

  return r
end

--- Fetch want tokens.
-- rate/burst are derived from limit/window by the caller, keeping this module IO-only.
-- @return table {granted, tokens, wait} or nil, err
function _M.grant(conf, key, want, ttl_ms, rate, burst)
  local r, nerr = redis:new()
  if not r then
    return nil, "cannot create redis client: " .. tostring(nerr)
  end

  local timeout = conf.redis.timeout or 1000
  if r.set_timeouts then
    r:set_timeouts(timeout, timeout, timeout)
  else
    r:set_timeout(timeout)
  end

  local ok, err = r:connect(conf.redis.host, conf.redis.port)
  if not ok then
    return nil, "connect: " .. tostring(err)
  end

  if conf.redis.password and conf.redis.password ~= "" then
    local aok, aerr = r:auth(conf.redis.password)
    if not aok then
      r:close()
      return nil, "auth: " .. tostring(aerr)
    end
  end

  if conf.redis.database and conf.redis.database > 0 then
    local sok, serr = r:select(conf.redis.database)
    if not sok then
      r:close()
      return nil, "select: " .. tostring(serr)
    end
  end

  local res, eerr = evalsha(r, SCRIPTS.token_bucket, 1, key,
                            tostring(rate),
                            tostring(burst),
                            tostring(want),
                            tostring(ttl_ms))
  if not res then
    r:close()
    return nil, "eval: " .. tostring(eerr)
  end

  -- D3: malformed responses are treated as Redis errors (close instead of keepalive, enter the fault branch)
  local parsed, perr = parse_grant_response(res, want)
  if not parsed then
    r:close()
    return nil, perr
  end

  -- Return the connection to the pool: without keepalive, high concurrency quickly exhausts local ports
  r:set_keepalive(10000, 100)

  return parsed
end

--- D1/D4: multi-key atomic grant for multi-rule α mode (deduct 1 per bucket, all-or-nothing).
-- keys[i] corresponds one-to-one with rates[i]/bursts[i]/ttls_ms[i] (derived from rules by the caller).
-- @return {ok=1, buckets={{tokens,wait}…}} or {ok=0, rejects={{rule,wait}…}}
--         or nil, err (connection/script/malformed response → the caller takes the fault branch)
function _M.grant_multi(conf, keys, rates, bursts, ttls_ms)
  local n = #keys
  local argv = { tostring(n) }
  for i = 1, n do
    argv[#argv + 1] = tostring(rates[i])
    argv[#argv + 1] = tostring(bursts[i])
    argv[#argv + 1] = tostring(ttls_ms[i])
  end

  local r, cerr = connect(conf)
  if not r then
    return nil, cerr
  end

  -- eval arguments must be explicitly flattened: an unpack in the middle of the argument list is truncated by Lua to 1 value
  -- (KEYS gets dropped and numkeys misaligns); only an unpack at the end expands fully.
  local args = { n }
  for i = 1, n do
    args[#args + 1] = keys[i]
  end
  for i = 1, #argv do
    args[#args + 1] = argv[i]
  end

  local res, eerr = evalsha(r, SCRIPTS.grant_multi, unpack(args))
  if not res then
    r:close()
    return nil, "eval: " .. tostring(eerr)
  end

  -- Same D3 technique: malformed responses treated as Redis errors (close instead of keepalive, enter the fault branch)
  local parsed, perr = parse_multi_grant_response(n, res)
  if not parsed then
    r:close()
    return nil, perr
  end

  r:set_keepalive(10000, 100)

  return parsed
end

--- GRANT_LEASE call (Phase 4): lease grant (bucket deduction + lease record creation, atomic in one script).
-- KEYS[1]=bucket key  KEYS[2]=lease key (Gate 4 task A: `build_lease_key(bucket_key, lease_id)`
-- appends ":lease:<lease_id>" after the bucket key, sharing the bucket key's hash tag ⇒ same Cluster slot;
-- the legacy format `<key_prefix>:lease:<lease_id>` is deprecated, the script itself unchanged — its KEYS
-- semantics depend only on what the caller passes; see docs/REMEDIATION.md for the KEYS order audit).
-- Error pass-through: LEASE_EXISTS / INVALID_ARGUMENT (script zero writes) and timeouts/disconnects/malformed responses
-- are all returned to the caller as-is (lease.lua classifies per design D4 — uncertain results are never retried or registered).
-- @return {granted, tokens, wait} (granted>=1 ⇒ record created; granted=0 ⇒ no record created)
--         or nil, err
function _M.grant_lease(conf, bucket_key, lease_id, pool_key, batch,
                        lease_ttl_ms, rate, capacity, bucket_ttl_ms)
  local lkey, lkey_err = keys_mod.build_lease_key(bucket_key, lease_id)
  if not lkey then
    return nil, lkey_err
  end

  local r, cerr = connect(conf)
  if not r then
    return nil, cerr
  end

  local res, eerr = evalsha(r, SCRIPTS.grant_lease, 2,
                            bucket_key, lkey,
                            tostring(batch),
                            tostring(lease_ttl_ms),
                            lease_id,
                            pool_key,
                            tostring(rate),
                            tostring(capacity),
                            tostring(bucket_ttl_ms))
  if not res then
    r:close()
    return nil, eerr
  end

  -- Malformed responses are treated as Redis errors (close instead of keepalive, enter the fault branch);
  -- want=batch: granted ∈ [0, batch] (partial grants allowed)
  local parsed, perr = parse_grant_response(res, batch)
  if not parsed then
    r:close()
    return nil, perr
  end

  r:set_keepalive(10000, 100)

  return parsed
end

return _M
