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
local lease = require "kong.plugins.rate-limit-advanced.lib.lease"

local _M = {}

-- V1 固定 Lease TTL（design D4/D9）：只管理 Redis Lease 元数据过期，
-- 与桶 TTL / 归还无关（V1 无 RETURN）。取 1h：
--   覆盖测试口径内最慢的本地消耗窗口（limit=100/window=3600/batch=20 ⇒ ~720s 消耗完一批），
--   同时给崩溃 Worker 的残留记录一个有界生命周期，防止记录无限累积。
-- Phase 5 引入 RETURN/max_lifetime 后该常量交还配置管理。
local LEASE_TTL_MS = 3600000

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
  -- D2/4.3：rules 模式运行时兜底校验（与 schema entity_check 双保险——
  -- 防绕过 Admin API 校验的配置注入：校验失败 → nil → handler 500 misconfigured）
  if conf.rules and #conf.rules > 0 then
    local rerr = _M.validate_rules(conf)
    if rerr then
      return nil, rerr
    end
    -- 多规则模式：返回 r1 的组键（日志主键）；组键全量由 check_multi 构造
    local keys, gerr = _M.build_group_keys(conf)
    if not keys then
      return nil, gerr
    end
    return keys[1]
  end

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

--- rules 模式运行时兜底校验（D2/4.3，纯函数，可 resty 单测）。
-- schema 已前置拒绝（400），这里是绕过 schema 注入 conf 时的第二道闸。
-- @return nil（合法）或 err string
function _M.validate_rules(conf)
  if #conf.rules > 8 then
    return "rules exceeds max of 8 rules"
  end
  if (conf.batch or 0) > 1 then
    return "batch must be 0 or 1 when rules is set (alpha strict mode has no local lease)"
  end
  for i = 1, #conf.rules do
    local rule = conf.rules[i]
    local dims = rule.limit_by or {}
    for j = 1, #dims do
      if dims[j] == "header" and (rule.header_name == nil or rule.header_name == "") then
        return "rules[" .. i .. "] limit_by contains 'header' but header_name is not set"
      end
    end
  end
  return nil
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

--- 单条 rule 的令牌桶参数（D3：桶结构沿用 tokens/ts，refill 公式与单桶同构）
function _M.rule_rate_and_burst(rule)
  local rate = rule.limit / rule.window
  local burst = rule.burst
  if not burst or burst <= 0 then
    burst = rule.limit
  end
  return rate, burst
end

-- D3：组指纹输入串——全部规则参数按序拼接。
-- 任一规则的 limit/window/burst/limit_by/header_name 变化 ⇒ 组指纹变 ⇒ 整组换新桶
--（代价：改一条规则 = 整组配额重置；header_name 仅在对应规则用到 header 维度时参与，
--  与单规则指纹约定一致，避免无关字段变更引起重置）。
local function group_fingerprint_input(conf)
  local segs = {}
  for i = 1, #conf.rules do
    local rule = conf.rules[i]
    local _, burst = _M.rule_rate_and_burst(rule)
    local s = "limit=" .. tostring(rule.limit)
      .. ";window=" .. tostring(rule.window)
      .. ";burst=" .. tostring(burst)
      .. ";limit_by=" .. table.concat(rule.limit_by, ",")
    for j = 1, #rule.limit_by do
      if rule.limit_by[j] == "header" then
        s = s .. ";header_name=" .. tostring(rule.header_name or "")
        break
      end
    end
    segs[#segs + 1] = "r" .. i .. "{" .. s .. "}"
  end
  return table.concat(segs, ";")
end

--- D3：组键构造。
-- 形如 kong:rl:{<ns>:g=<组指纹>:r<i>:<dim>=<val>:…}
-- 组内全部桶同 hash tag ⇒ 同 Redis Cluster slot（多键 EVAL 的 Cluster 硬前提）。
-- @return keys, rates, bursts, ttls_ms, rule_descs
--         或 nil, err（某规则 limit_by 含 header 但缺 header_name）
function _M.build_group_keys(conf)
  local fp = string.format("%08x", fnv1a32(group_fingerprint_input(conf)))
  local keys, rates, bursts, ttls, descs = {}, {}, {}, {}, {}
  for i = 1, #conf.rules do
    local rule = conf.rules[i]
    local parts = {}
    for j = 1, #rule.limit_by do
      local dim = rule.limit_by[j]
      if dim == "header" and (rule.header_name == nil or rule.header_name == "") then
        return nil, "rules[" .. i .. "] limit_by contains 'header' but header_name is not set"
      end
      parts[j] = dim .. "=" .. dim_value(dim, rule)
    end
    local rate, burst = _M.rule_rate_and_burst(rule)
    local tag = conf.namespace
      .. ":g=" .. fp
      .. ":r" .. i
      .. ":" .. table.concat(parts, ":")
    keys[i] = conf.redis.key_prefix .. ":{" .. tag .. "}"
    rates[i] = rate
    bursts[i] = burst
    ttls[i] = math.max(1, math.floor(rule.window * 2)) * 1000
    descs[i] = "rules[" .. i .. "]:" .. table.concat(rule.limit_by, "+")
  end
  return keys, rates, bursts, ttls, descs
end

--- D1：多规则 α 强一致决策（每请求一次多键原子 Lua，无本地库存）。
-- 全或无语义在 Redis 服务端单脚本内完成（D4）；此处只组装 decision。
-- 响应口径（D5）：
--   放行：remaining = min(各桶剩余)（瓶颈规则）、reset = 瓶颈桶的下一令牌时刻
--   429：retry_after = max(不足桶 wait)、封顶 = 不足桶 window 的最大值、
--        reject_rules = 不足规则的人读标识、reject_primary = 决定 Retry-After 的规则下标
-- @return decision table 或 nil, err
function _M.check_multi(conf)
  local now = ngx.now()
  local keys, rates, bursts, ttls, descs = _M.build_group_keys(conf)
  if not keys then
    return nil, rates
  end

  local parsed, err = redis_mod.grant_multi(conf, keys, rates, bursts, ttls)
  if not parsed then
    kong.log.err("rate-limit-advanced: redis grant_multi failed: ", tostring(err))
    return nil, err
  end

  if parsed.ok == 1 then
    -- 瓶颈规则 = 扣减后剩余最少的桶；Reset = 瓶颈桶的下一令牌时刻（wait=0 即 now）
    local min_tokens, min_i = math.huge, 1
    for i = 1, #parsed.buckets do
      local b = parsed.buckets[i]
      if b.tokens < min_tokens then
        min_tokens, min_i = b.tokens, i
      end
    end
    kong.log.notice(
      "[RL-DEBUG] multi_grant keys=", table.concat(keys, " | "),
      " remaining=", min_tokens, " bottleneck=r", min_i
    )
    return {
      allowed            = true,
      remaining          = math.max(0, math.floor(min_tokens)),
      reset              = math.floor(now + (parsed.buckets[min_i].wait or 0)),
      bottleneck         = min_i,
      multi_limit        = conf.rules[min_i].limit,
    }
  end

  -- ok=0：全不扣。Retry-After 取 max(wait)（封顶 = 不足规则 window 最大值），
  -- reject_primary = 该 max 所在规则（其 limit/window 决定 429 头口径）。
  local max_wait, primary, cap = -1, 1, 1
  local rule_descs = {}
  for _, rj in ipairs(parsed.rejects) do
    if rj.wait > max_wait then
      max_wait, primary = rj.wait, rj.rule
    end
    local w = conf.rules[rj.rule].window
    if w > cap then
      cap = w
    end
    rule_descs[#rule_descs + 1] = descs[rj.rule]
  end
  kong.log.notice(
    "[RL-DEBUG] multi_reject keys=", table.concat(keys, " | "),
    " reject=", table.concat(rule_descs, ","), " wait=", max_wait
  )
  return {
    allowed       = false,
    remaining     = 0,
    retry_after   = max_wait,
    reject_rules  = table.concat(rule_descs, ","),
    reject_primary = primary,
    reject_cap    = cap,
    multi_limit   = conf.rules[primary].limit,
  }
end

--- D2/D4/D7：单规则 batch>1 的 Lease 决策（Phase 6 接线）。
-- pool_key = 既有桶键（含策略指纹 + 维度值，D7）⇒ 本地库存与 Redis 桶一一对应，
-- 配置变化经由指纹变化自然隔离旧库存。
-- 流程：本地 TAKE（非 yield 原子）→ 有库存放行；
--       NEED_GRANT ⇒ GRANT_LEASE（D4 四分类）：
--         明确授予   ⇒ 登记 Lease（lease.grant 内完成）→ 本次请求再 TAKE 恰好消费 1 个
--         granted=0  ⇒ 429（既有 Retry-After 语义，wait 透传）
--         显式错误   ⇒ nil, err（LEASE_EXISTS / INVALID_ARGUMENT / 脚本装载失败）
--         不确定     ⇒ nil, err（不重试、不登记，允许损失——冻结决策）
-- V1 口径：无扫描器、无 RETURN、无自动归还；耗尽 Lease 由 lease.take 内 CLOSED 摘除。
-- @return decision table 或 nil, err（err 为字符串，沿 handler 既有故障分支）
function _M.check_lease(conf, key)
  local now      = ngx.now()
  local ttl_s    = math.max(1, math.floor(conf.window * 2))
  local ttl_ms   = ttl_s * 1000
  local rate, burst = _M.rate_and_burst(conf)
  local batch    = _M.resolve_batch(conf)
  -- fast path 本地无库存时，只能近似"下一令牌时刻"：一个补充周期 window/limit 秒
  local next_tick = math.ceil(1 / rate)

  -- 1) fast path：Worker 本地 TAKE，零网络 IO
  local tok, remaining = lease.take(key)
  if tok then
    kong.log.notice(
    "[RL-DEBUG] local_hit key=", key,
    " remaining=", remaining
    )
    local reset
    if remaining > 0 then
      reset = math.floor(now)          -- 下一令牌已可用
    else
      reset = math.floor(now + next_tick) -- 刚取走最后一个，保守近似
    end
    return {
      allowed   = true,
      remaining = math.max(0, remaining),
      reset     = reset,
    }
  end

  -- 2) 本地无库存 ⇒ GRANT_LEASE 申请新 Lease（D4 四分类）
  local res, gerr = lease.grant(conf, key, key, batch, LEASE_TTL_MS,
                                rate, burst, ttl_ms)
  if not res then
    -- explicit_error 与 uncertain 均进既有故障分支（Fail-close）：
    -- 显式错误确定零写入、不确定结果可能已执行——两者都不允许伪装成 429
    kong.log.err("rate-limit-advanced: lease grant failed (",
                 tostring(gerr.kind), "): ", tostring(gerr.err))
    return nil, gerr.err
  end
  kong.log.notice(
  "[RL-DEBUG] lease_grant key=", key,
  " lease_id=", res.lease_id,
  " granted=", res.granted,
  " wait=", res.wait
  )

  -- 3) 明确不足（granted=0，桶令牌数不足 1）⇒ 429（既有语义，不建 Lease）
  if res.ok == false then
    local wait = res.wait
    if not wait or wait <= 0 then
      wait = 1
    end
    return {
      allowed     = false,
      remaining   = 0,
      retry_after = wait,
    }
  end

  -- 4) 明确授予（granted>=1，Lease 已登记）⇒ 本次请求必须恰好消费 1 个，
  --    不得只登记库存却漏掉当前请求（granted>=1 ⇒ active 非空 ⇒ TAKE 必成功；
  --    防御分支按故障处理，绝不放行未授权库存）
  local tok2, remaining2 = lease.take(key)
  if not tok2 then
    kong.log.err("rate-limit-advanced: lease take after grant returned NEED_GRANT: ",
                 tostring(key))
    return nil, "lease take after grant returned NEED_GRANT"
  end
  kong.log.notice(
  "[RL-DEBUG] lease_take_after_grant key=", key,
  " remaining=", remaining2
  )

  -- slow path allowed：wait=0 ⇒ 下一令牌已可用；wait>0 ⇒ 部分授予后桶内 tokens<1
  return {
    allowed   = true,
    remaining = math.max(0, remaining2),
    reset     = math.floor(now + (res.wait or 0)),
  }
end

--- 核心决策。
-- remaining 口径（快/慢路径一致）：均为"本节点视角"的剩余——
-- fast path 是本地库存余量；slow path 的 granted-1 恰好等于 fill 后的本地库存。
-- Reset 口径（D1）："下一令牌可用的 Unix 秒"；429 路径由 handler 用封顶后的
-- Retry-After 推导（同口径），此处不回 reset。
-- @return table {allowed, remaining, reset, retry_after} 或 nil, err
function _M.check(conf, key)
  -- D1：多规则模式走 α 强一致分支（无本地库存，每请求一次多键原子 Lua）
  if conf.rules and #conf.rules > 0 then
    return _M.check_multi(conf)
  end

  local now      = ngx.now()
  local ttl_s    = math.max(1, math.floor(conf.window * 2))
  local ttl_ms   = ttl_s * 1000
  local rate, burst = _M.rate_and_burst(conf)
  -- fast path 本地无库存时，只能近似"下一令牌时刻"：一个补充周期 window/limit 秒
  local next_tick = math.ceil(1 / rate)

  -- batch 先解析：batch=1 = 严格全局一致模式，完全绕开本地库存（D4）
  local batch = _M.resolve_batch(conf)

  -- 1) Lease 路径：单规则 batch>1 ⇒ Worker 本地 TAKE / GRANT_LEASE（Phase 6）
  if batch > 1 then
    return _M.check_lease(conf, key)
  end

  -- 2) slow path：向全局桶领一批（batch=1 时每请求必经此路径）

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
    -- 429 的 Reset 由 handler 用封顶后的 Retry-After 推导（同口径），此处不回 reset
    return {
      allowed     = false,
      remaining   = 0,
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

  -- slow path allowed：wait=0 ⇒ 下一令牌已可用；wait>0 ⇒ 部分授予后桶内 tokens<1
  return {
    allowed   = true,
    remaining = granted.granted - 1,
    reset     = math.floor(now + (granted.wait or 0)),
  }
end

return _M
