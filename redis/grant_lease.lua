-- Standalone lease grant script (GRANT_LEASE), for bare redis-cli verification.
-- Dual-source synced with the embedded GRANT_LEASE in kong/plugins/rate-limit-advanced/lib/redis.lua (diff-checked).
--
-- One atomic call completes: argument validation → bucket refill → partial grant decision → bucket deduction → lease record creation (OPEN) → TTL set.
-- Do NOT split into "deduct the bucket first, the client creates the record afterwards" (a fault between the two operations leaves quota ownership undecidable).
-- Redis Lua runtime errors do not roll back executed writes: all validations are front-loaded before any write.
--
-- Refill persistence semantics (unified with TOKEN_BUCKET, review P1-1 verdict):
--   elapsed = max(0, now - ts); tokens = min(capacity, old_tokens + rate*elapsed);
--   ts only moves forward; the **insufficient branch with granted<1 also writes back the refilled tokens/ts and updates the bucket TTL**
--   (GRANT_MULTI's "insufficient writes nothing" is required by the multi-key all-or-nothing semantics; not applicable to single-key scripts).
-- wait return semantics (review P1-3 verdict): consistent with the TOKEN_BUCKET contract —
--   seconds until the next token is available, computed from the **post-deduction** tokens (wait>0 on partial grants).
-- Bucket state numeric validity (review P1-2 verdict): tokens ∈ [0, capacity], ts ≥ 0, finite numbers;
--   invalid states return a clear error code, **no silent correction**, data stays unchanged.
--
-- Usage:
--   redis-cli --eval redis/grant_lease.lua <bucket key> , <lease key> , batch lease_ttl_ms lease_id pool_key rate capacity bucket_ttl_ms
--   KEYS[1] = bucket key (tokens/ts)
--   KEYS[2] = kong:rl:lease:{lease_id} ({...} is placeholder syntax; the actual key has no braces)
--   ARGV[1] = batch (grant cap for this batch, positive integer)
--   ARGV[2] = lease_ttl_ms (lease record TTL: max_lifetime + 3×redis_timeout + 60s, computed by the caller)
--   ARGV[3] = lease_id (globally unique)
--   ARGV[4] = pool_key (rate-limit bucket key / policy version, validated on RETURN)
--   ARGV[5] = rate (replenished per second, unified source with the other scripts)
--   ARGV[6] = capacity (bucket capacity, unified source with the other scripts)
--   ARGV[7] = bucket_ttl_ms (bucket TTL: 2×window, consistent with TOKEN_BUCKET)
--
-- Returns:
--   success (granted>0): { granted, tokens(string), wait(string) }, and creates a lease with status=OPEN
--   insufficient (tokens<1 after refill): { 0, tokens(string), wait(string) }, no lease created;
--     but **writes back the refilled bucket state and TTL** (consistent with TOKEN_BUCKET)
--   failure: error codes (LEASE_EXISTS / INVALID_ARGUMENT, zero writes)
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
