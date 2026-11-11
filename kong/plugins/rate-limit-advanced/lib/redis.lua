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

-- D1：wait 统一为"距下一个令牌可用的秒数"。
-- tokens >= 1 时 (1-tokens) <= 0，钳到 0（下一令牌已可用）；
-- tokens < 1 时为补足一个整令牌所需等待。
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

--- D3：防御性校验 EVAL 返回值（纯函数，不依赖 cosocket，可被 resty 单测直接调用）。
-- 合法形态：{ granted(整数, 0..want), tokens(数值), wait(数值, >=0) }。
-- 任一不满足 → nil, 原因；调用方（grant）将其视为 Redis 异常并进入故障分支。
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

  -- D3：畸形返回按 Redis 异常处理（close 而非 keepalive，进故障分支）
  local parsed, perr = parse_grant_response(res, want)
  if not parsed then
    r:close()
    return nil, perr
  end

  -- 放回连接池：不 keepalive 的话，高并发下会迅速耗尽本地端口
  r:set_keepalive(10000, 100)

  return parsed
end

return _M
