-- ============================================================
-- rate-limit-advanced / lib/lease.lua
-- Worker 本地 Lease 管理器（Phase 4，V1：不接扫描器/生命周期）。
--
-- 所有权模型（design D2/D3/D4）：
--   * 每 Worker 一份模块状态（OpenResty 每 Worker 独立 Lua VM），
--     其他 Worker 结构性不可见 ⇒ 无共享、无跨 Worker 接管。
--   * TAKE 在不含 yield 点的同步片段内完成查找/检查/递减
--     （OpenResty 协程只在 yield 点切换 ⇒ 片段内无交错，
--     这是原子性的完整证明，不需要任何补偿路径）。
--   * V1 状态机 ACTIVE → CLOSED 单向：库存耗尽（remaining=0）⇒ CLOSED，
--     从可消费集合摘除；对象保留在本地 table 仅作诊断记录（不删除）；
--     无 CLOSING 归还态、无 Redis RETURN 调用、不清理 Redis 记录、
--     不做库存补偿（Phase 5 恢复自动归还时才引入，见 tasks.md Phase 5 DEFERRED）。
--   * 多 Lease 并存：同 pool_key 可并存多个 Lease（独立 lease_id），
--     GRANT 确定成功后在本非 yield 段登记（追加不覆盖）；
--     Redis 侧 GRANT_LEASE 已原子扣桶 ⇒ 并存不会重复分配全局库存。
--   * GRANT 结果不明确（超时/断开/畸形）⇒ 不重试、不登记本地库存，
--     允许库存损失（D4；Redis 可能已执行：桶已扣、记录已建）。
-- ============================================================
local ngx_now = ngx.now
local ngx_worker_id = ngx.worker.id

local redis_mod = require "kong.plugins.rate-limit-advanced.lib.redis"

local _M = {}

-- ------------------------------------------------------------
-- Worker 级状态（design D2 数据结构；每 Worker 一份）
--   pools[pool_key] = { leases = {lease_obj,...}  全量（诊断记录，只增不删）
--                       active = {lease_obj,...}  可消费集合（插入序，同一对象的引用）}
--   lease_obj = { lease_id, pool_key, granted, remaining, consumed,
--                 created_at, state }  -- state: "ACTIVE" | "CLOSED"（D2 冻结字段名）
--   V1 无 idle_threshold / max_lifetime / last_used_at（Phase 5 恢复时引入）
--   不变量：remaining + consumed = granted；0 ≤ remaining ≤ granted
-- ------------------------------------------------------------
_M._pools = {}

-- 进程内生命周期计数（D8 指标的本地口径）
_M._counters = { leases = 0, tokens_granted = 0, tokens_consumed = 0, closed = 0 }

-- ------------------------------------------------------------
-- lease_id 生成（D4）：<hostname>:<worker_id>:<进程内单调计数器>:<随机 hex>
-- 冲突由 Redis 侧 EXISTS 检查兜底（LEASE_EXISTS → 故障分支）；
-- 生成规则使冲突概率≈0。
-- ------------------------------------------------------------
local lease_seq = 0

local function host_name()
  local ok, v = pcall(function() return ngx.var.hostname end)
  if ok and type(v) == "string" and v ~= "" then
    return v
  end
  -- resty 单测 / 无请求上下文：容器 HOSTNAME 兜底（仅诊断标识，唯一性靠计数器+随机）
  return os.getenv("HOSTNAME") or "unknown"
end

local cached_host
local seeded = false
local function ensure_random_seed()
  if seeded then
    return
  end
  -- 每 VM 首次生成前播种：LuaJIT math.random 不播种时在每个新 VM 输出相同序列，
  -- 跨 Worker 重启会生成确定性碰撞的 lease_id（Redis EXISTS 兜底正确拒绝，
  -- 但违反 D4"生成规则使冲突概率≈0"）。熵源 = 毫秒时间 + Worker PID。
  local pid = 0
  pcall(function() pid = ngx.worker.pid() or 0 end)
  math.randomseed(math.floor(ngx_now() * 1000) + pid)
  seeded = true
end

function _M.new_lease_id()
  if not cached_host then
    cached_host = host_name()
  end
  ensure_random_seed()
  lease_seq = lease_seq + 1
  return string.format("%s:%s:%d:%06x",
    cached_host,
    tostring(ngx_worker_id and ngx_worker_id() or 0),
    lease_seq,
    math.random(0, 0xffffff))
end

local function pool_of(pool_key)
  local pool = _M._pools[pool_key]
  if not pool then
    pool = { leases = {}, active = {} }
    _M._pools[pool_key] = pool
  end
  return pool
end

-- ------------------------------------------------------------
-- 登记一个已授予的 Lease（任务 4.1/4.4）。
-- GRANT 确定成功（classify=success）后调用；非 yield 同步片段；
-- 追加不覆盖（D2 多 Lease 并存约束）。
-- @return lease 对象（诊断/测试用），或 nil, err（参数非法）
-- ------------------------------------------------------------
function _M.register(pool_key, lease_id, granted, created_at)
  if type(pool_key) ~= "string" or pool_key == "" then
    return nil, "pool_key required"
  end
  if type(lease_id) ~= "string" or lease_id == "" then
    return nil, "lease_id required"
  end
  if type(granted) ~= "number"
     or granted ~= math.floor(granted)
     or granted < 1 or granted >= 2^53 then
    return nil, "granted must be a positive integer: " .. tostring(granted)
  end

  local pool = pool_of(pool_key)
  local lease = {
    lease_id   = lease_id,
    pool_key   = pool_key,
    granted    = granted,
    remaining  = granted,          -- remaining + consumed = granted（守恒起点）
    consumed   = 0,
    created_at = created_at or ngx_now(),
    state      = "ACTIVE",
  }
  pool.leases[#pool.leases + 1] = lease
  pool.active[#pool.active + 1] = lease
  _M._counters.leases = _M._counters.leases + 1
  _M._counters.tokens_granted = _M._counters.tokens_granted + granted
  return lease
end

-- ------------------------------------------------------------
-- TAKE：原子消耗 1 个本地库存令牌（任务 4.2）。
-- 本函数整体是一个非 yield 同步片段：不得出现 cosocket / ngx.sleep /
-- timer 等 yield 点（协程探针测试断言）；不访问 Redis、无等待、无补偿路径。
--
-- D2 TAKE 顺序：按插入序遍历可消费集合（active），取首个有存量者。
-- 耗尽（remaining=0）⇒ 同片段标记 CLOSED 并从 active 摘除（D3 V1 耗尽处理）；
-- 对象保留在 leases 列表仅作诊断。
-- @return true, remaining(扣减后), lease_id | false, "NEED_GRANT"
-- ------------------------------------------------------------
function _M.take(pool_key)
  local pool = _M._pools[pool_key]
  if not pool then
    return false, "NEED_GRANT"
  end

  local active = pool.active
  for i = 1, #active do
    local l = active[i]
    -- active 集合内恒为 ACTIVE 且 remaining>0（耗尽即摘除）；防御性保持该结构
    if l.state == "ACTIVE" and l.remaining > 0 then
      l.remaining = l.remaining - 1
      l.consumed = l.consumed + 1
      _M._counters.tokens_consumed = _M._counters.tokens_consumed + 1
      if l.remaining == 0 then
        l.state = "CLOSED"
        table.remove(active, i)
        _M._counters.closed = _M._counters.closed + 1
      end
      return true, l.remaining, l.lease_id
    end
  end
  return false, "NEED_GRANT"
end

-- ------------------------------------------------------------
-- GRANT_LEASE 结果分类（任务 4.4，design D4；纯函数）。
-- 输入为 redis.grant_lease 的返回（已过 parse_grant_response 防御校验）：
--   parsed = { granted, tokens, wait }  或  nil, err
-- @return class, data
--   "success"        data = parsed（granted ≥ 1，可登记本地库存）
--   "insufficient"   data = parsed（granted = 0，tokens<1，未建记录）
--   "explicit_error" data = err（确定未执行、零写入：LEASE_EXISTS/参数非法/
--                                脚本装载失败——NOSCRIPT 为执行前错误）
--   "uncertain"      data = err（结果不明确：超时/断开/畸形返回——
--                                Redis 可能已执行 ⇒ 不重试、不登记，允许损失）
-- ------------------------------------------------------------
local EXPLICIT_ERR_MARKS = {
  "LEASE_EXISTS",
  "INVALID_ARGUMENT",
  "script load failed",
  "script still missing after reload",
}

local function is_explicit_grant_err(err)
  if type(err) ~= "string" then
    return false
  end
  for i = 1, #EXPLICIT_ERR_MARKS do
    if string.find(err, EXPLICIT_ERR_MARKS[i], 1, true) then
      return true
    end
  end
  return false
end

function _M.classify_grant(parsed, err)
  if parsed ~= nil then
    if type(parsed) ~= "table" or parsed.granted == nil
       or parsed.granted < 0 then
      -- 防御：不应到达（redis 层已校验）；按"可能已执行"保守处理
      return "uncertain", err or "malformed grant_lease response"
    end
    if parsed.granted >= 1 then
      return "success", parsed
    end
    return "insufficient", parsed
  end
  if is_explicit_grant_err(err) then
    return "explicit_error", err
  end
  return "uncertain", err
end

-- ------------------------------------------------------------
-- 申请一个 Lease（任务 4.4 GRANT 调用接线）。
-- 传输层可注入（测试 stub）；默认走 lib/redis.grant_lease（EVALSHA）。
-- 结果不明确 ⇒ 不重试、不登记本地库存（D4）。
-- cosocket yield 只发生在传输层调用内部；登记/分类不含等待点。
-- @return
--   成功     { ok = true, granted, tokens, wait, lease_id, lease }
--   不足     { ok = false, reason = "insufficient", tokens, wait }
--            （granted=0：调用方按既有 429 语义处理，不建 Lease）
--   明确错误 nil, { kind = "explicit_error", err = ... }（调用方走既有故障分支）
--   不确定   nil, { kind = "uncertain", err = ... }（同上，且不重试）
-- ------------------------------------------------------------
_M._transport = nil  -- 测试注入点；nil ⇒ redis_mod.grant_lease

function _M.grant(conf, pool_key, bucket_key, batch, lease_ttl_ms,
                  rate, capacity, bucket_ttl_ms)
  local transport = _M._transport or redis_mod.grant_lease
  local lease_id = _M.new_lease_id()

  local parsed, err = transport(conf, bucket_key, lease_id, pool_key,
                                batch, lease_ttl_ms, rate, capacity, bucket_ttl_ms)
  local class, data = _M.classify_grant(parsed, err)

  if class == "success" then
    local lease, rerr = _M.register(pool_key, lease_id, data.granted)
    if not lease then
      -- 登记失败（理论上不可能：granted 已过两层校验）⇒ 按不确定损失处理，
      -- 不得把未登记的库存当作可用
      return nil, { kind = "uncertain", err = "register failed: " .. tostring(rerr) }
    end
    return {
      ok       = true,
      granted  = data.granted,
      tokens   = data.tokens,
      wait     = data.wait,
      lease_id = lease_id,
      lease    = lease,
    }
  elseif class == "insufficient" then
    return { ok = false, reason = "insufficient", tokens = data.tokens, wait = data.wait }
  else
    return nil, { kind = class, err = data }
  end
end

-- ------------------------------------------------------------
-- D8 指标（V1 口径）：lease.stats() 供测试与报告取证。
--   leases / tokens_granted / tokens_consumed / closed：进程内生命周期累计
--   active：当前可消费 Lease 数；local_remaining：Σ 本地 remaining
--   outstanding（= local_remaining）；V1 账目：granted = consumed + outstanding
--   （无丢失时恒等成立；崩溃/超时损失不入该恒等式——见 design D8）
-- ------------------------------------------------------------
function _M.stats()
  local active, remaining = 0, 0
  for _, pool in pairs(_M._pools) do
    for i = 1, #pool.active do
      active = active + 1
      remaining = remaining + pool.active[i].remaining
    end
  end
  local c = _M._counters
  return {
    leases          = c.leases,
    granted         = c.tokens_granted,
    consumed        = c.tokens_consumed,
    closed          = c.closed,
    active          = active,
    local_remaining = remaining,
  }
end

-- ------------------------------------------------------------
-- 结构不变量校验（任务 4.2/4.4 的"结构断言"；测试/诊断用）：
--   * remaining + consumed = granted（守恒）
--   * 0 ≤ remaining ≤ granted（无负库存、不超发本地）
--   * state ∈ { ACTIVE, CLOSED }；CLOSED ⇒ remaining = 0
--   * active 集合内均为 ACTIVE 且 remaining > 0，且每对象至多出现一次
--   * 计数器与逐对象求和无漂移
-- @return true | false, reason
-- ------------------------------------------------------------
function _M.invariants()
  local n_leases = 0
  local sum_granted, sum_consumed = 0, 0
  for _, pool in pairs(_M._pools) do
    local seen_active = {}
    for i = 1, #pool.leases do
      local l = pool.leases[i]
      if type(l.granted) ~= "number" or l.granted < 1 or l.granted >= 2^53 then
        return false, "granted invalid: " .. tostring(l.granted)
      end
      if type(l.remaining) ~= "number"
         or l.remaining < 0 or l.remaining > l.granted then
        return false, "remaining out of range: " .. tostring(l.remaining)
      end
      if l.remaining + l.consumed ~= l.granted then
        return false, "conservation broken: " .. l.lease_id
      end
      if l.state ~= "ACTIVE" and l.state ~= "CLOSED" then
        return false, "bad state: " .. tostring(l.state)
      end
      if l.state == "CLOSED" and l.remaining ~= 0 then
        return false, "closed with remaining: " .. l.lease_id
      end
      n_leases = n_leases + 1
      sum_granted = sum_granted + l.granted
      sum_consumed = sum_consumed + l.consumed
    end
    for i = 1, #pool.active do
      local l = pool.active[i]
      if l.state ~= "ACTIVE" or l.remaining <= 0 then
        return false, "active contains non-consumable lease"
      end
      if seen_active[l] then
        return false, "duplicate object in active set"
      end
      seen_active[l] = true
    end
  end
  local c = _M._counters
  if c.leases ~= n_leases
     or c.tokens_granted ~= sum_granted
     or c.tokens_consumed ~= sum_consumed then
    return false, "counter drift"
  end
  return true
end

-- ------------------------------------------------------------
-- 清空 Worker 级状态（仅测试使用：等价于 Worker 重启）。
-- ------------------------------------------------------------
function _M.reset()
  _M._pools = {}
  _M._counters = { leases = 0, tokens_granted = 0, tokens_consumed = 0, closed = 0 }
  lease_seq = 0
end

return _M
