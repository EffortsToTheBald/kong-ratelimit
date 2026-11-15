-- Standalone multi-key atomic script (D4), for bare redis-cli verification of the "all-or-nothing" semantics.
-- Dual-source synced with the embedded GRANT_MULTI in kong/plugins/rate-limit-advanced/lib/redis.lua (diff-checked).
-- Usage:
--   redis-cli --eval redis/multi_bucket.lua k1 , k2 , 2 , r1_rate r1_burst r1_ttl r2_rate r2_burst r2_ttl
--   KEYS   = per-rule bucket keys (same hash tag within the group ⇒ same slot)
--   ARGV[1]= n (number of rules), then 3 params per rule: rate burst ttl_ms
-- Returns:
--   success { 1, tokens_1, wait_1, tokens_2, wait_2, ... } (after deduction, tokens/wait per bucket)
--   failure { 0, rule index, wait, ... } (1-based indices of insufficient rules with their waits, all buckets untouched)
-- Note: floats must be returned via tostring, otherwise Redis truncates numbers to integers.
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
