-- Standalone token bucket script, used on Day 1 for bare redis-cli verification of the semantics.
-- Usage:
--   redis-cli --eval redis/token_bucket.lua rl:test , 1.67 100 1 120000
--   Argument order: rate burst want ttl_ms
--
-- Returns { granted, tokens, wait }
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
