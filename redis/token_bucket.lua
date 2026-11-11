-- 独立的令牌桶脚本，用于 Day 1 在 redis-cli 里裸跑验证语义。
-- 用法：
--   redis-cli --eval redis/token_bucket.lua rl:test , 1.67 100 1 120000
--   参数顺序：rate burst want ttl_ms
--
-- 返回 { granted, tokens, wait }
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

-- P0-4：ts 只前进不后退。时钟回拨期间不补充、也不把 ts 改小，
-- 否则时钟追上后，同一段时间会被二次计费，凭空多出令牌。
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

local wait = 0
if tokens < 1 and rate > 0 then
  wait = (1 - tokens) / rate
end

redis.call('HSET', key, 'tokens', tostring(tokens), 'ts', tostring(ts))
redis.call('PEXPIRE', key, ttl)

return { granted, tostring(tokens), tostring(wait) }
