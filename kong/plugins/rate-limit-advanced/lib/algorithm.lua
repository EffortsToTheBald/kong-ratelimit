-- ============================================================
-- rate-limit-advanced / lib/algorithm.lua
-- 限流主流程：构建 key → 消耗本地库存 → 不够则向 Redis 批量领取 → 决策
--
-- 这个模块是"唯一一条代码路径"：batch=1 就是严格全局一致，
-- batch=N 就是每 N 个请求一次 Redis。没有第二套实现。
-- ============================================================
local bit = require "bit"

local store = require "kong.plugins.rate-limit-advanced.lib.store"
local redis_mod = require "kong.plugins.rate-limit-advanced.lib.redis"

local _M = {}

local MAX_DIM_VALUE_LEN = 256

-- FNV-1a 32-bit：h = (h ^ byte) * 16777619 mod 2^32（P0-1/D1）。
-- Lua number 是 double，h * 16777619 会超 53 位精度，按 16 位拆乘保证精确。
local function fnv1a32(s)
  local h = 2166136261 -- 0x811c9dc5
  for i = 1, #s do
    h = bit.bxor(h, string.byte(s, i))
    local lo = bit.band(h, 0xffff)
    local hi = bit.rshift(h, 16)
    h = bit.band(lo * 16777619 + bit.band(hi * 16777619, 0xffff) * 0x10000, 0xffffffff)
  end
  -- LuaJIT 的 bit.band 返回带符号 32 位结果；归一化成无符号，
  -- 否则 %08x 会符号扩展成 16 位（如 ffffffff8039753e）。
  return h % 0x100000000
end

--- 策略指纹输入串（D1）：limit、window、解析后 burst、limit_by 顺序、
-- header_name（仅 limit_by 含 header 时参与）。不含 batch：batch 是运输参数，
-- 不改变桶的身份，算进指纹会让调 batch 就清空整个桶。
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

--- 策略指纹（P0-1，D1）。纯函数：不依赖 kong.*，可在 resty 下直接单测。
-- @return 8 位小写 hex 字符串
function _M.policy_fingerprint(conf)
  return string.format("%08x", fnv1a32(fingerprint_input(conf)))
end

local function dim_value(dim, conf)
  if dim == "consumer" then
    local consumer = kong.client.get_consumer()
    return consumer and consumer.id or "anon"

  elseif dim == "ip" then
    -- get_forwarded_ip() = realip 处理后的客户端地址：仅当 Kong 配置了 trusted_ips
    -- 时才采信上游转发头；默认（trust none）即为直接对端 IP，伪造 XFF 无效。
    -- 回退必须是 PDK 真实存在的 get_ip()（直连对端，不可伪造）。
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

--- 构建 Redis key。
-- 形如：kong:rl:{rl:p=1a2b3c4d:ip=10.0.0.7:path=/echo}
-- 花括号是 Redis Cluster 的 hash tag，保证同一逻辑 key 落在同一 slot；
-- p= 策略指纹（P0-1）：限流参数一变即得新 key/新桶，旧桶与旧本地库存随 TTL 自然淘汰。
function _M.build_key(conf)
  local parts = {}

  for i = 1, #conf.limit_by do
    local dim = conf.limit_by[i]

    if dim == "header" and (conf.header_name == nil or conf.header_name == "") then
      return nil, "limit_by contains 'header' but header_name is not set"
    end

    parts[i] = dim .. "=" .. dim_value(dim, conf)
  end

  local tag = conf.namespace
    .. ":p=" .. _M.policy_fingerprint(conf)
    .. ":" .. table.concat(parts, ":")
  return conf.redis.key_prefix .. ":{" .. tag .. "}"
end

--- batch 的实际取值。0 = auto。
-- 公式：clamp(floor(limit / 50), 1, 50)
-- 含义：容忍单节点 2% 的令牌滞留，最多 50 个/次以避免突发放大。
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

--- 由 limit/window 推导令牌桶参数
function _M.rate_and_burst(conf)
  local rate = conf.limit / conf.window
  local burst = conf.burst
  if not burst or burst <= 0 then
    burst = conf.limit
  end
  return rate, burst
end

--- 核心决策。
-- @return table {allowed, remaining, reset, retry_after} 或 nil, err
function _M.check(conf, key)
  local now      = ngx.now()
  local ttl_s    = math.max(1, math.floor(conf.window * 2))
  local ttl_ms   = ttl_s * 1000
  local reset_at = math.floor(now + conf.window)

  -- batch 先解析：batch=1 = 严格全局一致模式，完全绕开本地库存（D4）
  local batch = _M.resolve_batch(conf)

  -- 1) fast path：本地库存直接扣减，零网络 IO（batch>1 才有库存语义）
  if batch > 1 then
    local ok, remaining = store.take(key)
    if ok then
      kong.log.notice(
      "[RL-DEBUG] local_hit key=", key,
      " remaining=", remaining
      )
      return {
        allowed   = true,
        remaining = math.max(0, remaining),
        reset     = reset_at,
      }
    end
  end

  -- 2) slow path：向全局桶领一批（batch=1 时每请求必经此路径）
  local rate, burst = _M.rate_and_burst(conf)

  local granted, err = redis_mod.grant(conf, key, batch, ttl_ms, rate, burst)
  if not granted then
    -- rule.md §9.1 问题A：必须先判 nil 再解引用 granted.*，
    -- 否则 Redis 失败时这里直接抛 Lua 异常（500），fault_tolerant 分支永远走不到。
    kong.log.err("rate-limit-advanced: redis grant failed: ", tostring(err))
    return nil, err
  end
  kong.log.notice(
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
    return {
      allowed     = false,
      remaining   = 0,
      reset       = reset_at,
      retry_after = wait,
    }
  end
  -- 本次消耗 1 个，其余放进本地库存（batch=1 恒 granted=1，不产生库存）
  if batch > 1 and granted.granted > 1 then
    kong.log.notice(
    "[RL-DEBUG] local_fill key=", key,
    " fill=", math.max(0, granted.granted - 1)
    )
    store.fill(key, granted.granted - 1, ttl_s)
  end

  return {
    allowed   = true,
    remaining = granted.granted - 1,
    reset     = reset_at,
  }
end

return _M
