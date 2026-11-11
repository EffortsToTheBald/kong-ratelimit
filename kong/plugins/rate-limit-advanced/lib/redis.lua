-- ============================================================
-- rate-limit-advanced / lib/redis.lua
-- Redis 连接（keepalive 复用）+ 内嵌令牌桶脚本。
--
-- 为什么要内嵌脚本而不是读文件：
--   1) 插件目录只读挂载，避免运行期 IO
--   2) EVAL 的脚本文本会被 Redis 按 SHA 缓存，反复调用不会重复解析
-- ============================================================
local redis = require "resty.redis"

local _M = {}

-- ------------------------------------------------------------
-- 令牌桶（服务端时间）
--
-- KEYS[1] bucket key
-- ARGV[1] rate   每秒补充的令牌数
-- ARGV[2] burst  桶容量
-- ARGV[3] want   本次想领几个
-- ARGV[4] ttl    过期时间（毫秒）
--
-- 返回 { granted(整数), tokens(字符串), wait(字符串) }
--
-- 注意：
--   * TIME 取 Redis 自己的时钟，消除多网关节点的时钟漂移
--   * 浮点必须 tostring 返回，否则 Redis 会把 number 截断成整数
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
]]

_M.script = TOKEN_BUCKET

--- 领取 want 个令牌。
-- rate/burst 由调用方从 limit/window 推导后传入，保持本模块只负责 IO。
-- @return table {granted, tokens, wait} 或 nil, err
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

  local res, eerr = r:eval(TOKEN_BUCKET, 1, key,
                           tostring(rate),
                           tostring(burst),
                           tostring(want),
                           tostring(ttl_ms))
  if not res then
    r:close()
    return nil, "eval: " .. tostring(eerr)
  end

  -- 放回连接池：不 keepalive 的话，高并发下会迅速耗尽本地端口
  r:set_keepalive(10000, 100)

  return {
    granted = tonumber(res[1]) or 0,
    tokens  = tonumber(res[2]) or 0,
    wait    = tonumber(res[3]) or 0,
  }
end

return _M
