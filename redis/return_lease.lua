-- Standalone lease return script (RETURN_LEASE), for bare redis-cli verification.
-- Dual-source synced with the embedded RETURN_LEASE in kong/plugins/rate-limit-advanced/lib/redis.lua (diff-checked).
--
-- One atomic call completes: argument validation → read-only validation → **RETURNED idempotent commit point** → bucket update.
-- Write-order iron rule: mark RETURNED first (idempotent commit point), then update the bucket —
--   Redis Lua runtime errors do not roll back: with "add to the bucket first, mark afterwards", an interruption + retry would double-add the bucket (over-grant);
--   with the mark first, an interruption ⇒ retry yields ALREADY_RETURNED and does not re-add the bucket (losses allowed).
--
-- Usage:
--   redis-cli --eval redis/return_lease.lua <lease key> , <bucket key> , requested pool_key bucket_ttl_ms rate capacity
--   KEYS[1] = kong:rl:lease:{lease_id}
--   KEYS[2] = bucket key
--   ARGV[1] = requested (local remaining snapshot at lease close, non-negative integer <2^53)
--   ARGV[2] = pool_key (validated against the lease record)
--   ARGV[3] = bucket_ttl_ms (bucket TTL: 2×window, consistent with the grant side)
--   ARGV[4] = rate
--   ARGV[5] = capacity
--
-- Returns:
--   success: { requested, applied, discarded } (requested=0 still completes OPEN→RETURNED with applied=discarded=0)
--   idempotent/error: error codes — ALREADY_RETURNED / RETURN_CONFLICT / LEASE_NOT_FOUND /
--              INVALID_LEASE_STATE / POOL_MISMATCH / INVALID_REQUESTED /
--              BUCKET_NOT_FOUND / INVALID_ARGUMENT (all zero writes)
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
