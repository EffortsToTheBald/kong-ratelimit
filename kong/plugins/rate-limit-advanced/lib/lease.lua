-- ============================================================
-- rate-limit-advanced / lib/lease.lua
-- Worker 本地 Lease 管理器（关口三整改：Pool 生命周期 + 过期 + 账目）。
-- 设计依据：docs/REMEDIATION.md 关口二冻结版（e0c3cf1）。
--
-- 所有权模型（不变）：
--   * 每 Worker 一份模块状态（OpenResty 每 Worker 独立 Lua VM）。
--   * TAKE / 摘除 / 登记 / 计数全部在不含 yield 点的同步片段内完成。
--   * GRANT 结果不明确 ⇒ 不重试、不登记本地库存（D4，不变）。
--
-- 关口三新增（冻结设计逐条落地）：
--   * Pool 生命周期：register 创建；active 空且空闲超 max_age 由 Timer 回收；
--     MAX_POOLS 压力下只淘汰无 ACTIVE Lease 的 Pool（零库存损失）。
--   * 过期：created_at + pool.max_age/1000 < ngx.now()（秒/毫秒约定）⇒ EXPIRED，
--     remaining 计入 discarded_tokens（唯一来源），不归还 Redis。
--   * TAKE 过期判定：候选 O(1) 比较，过期即摘除；方案 B 下 #active ≤ 1
--     ⇒ 最坏扫描严格 O(1)。
--   * 单一摘除函数 expire_lease：TAKE / GRANT 清扫 / Timer 三路径共用，
--     计数逻辑仅一份 ⇒ discarded 不重复计数。
--   * 单在途 GRANT：_inflight[pool_key] 标志；置位期间的并发 GRANT 由
--     algorithm 层降级为 batch=1 直连（不登记）。
--   * 账目恒等式：confirmed_granted = consumed + outstanding + discarded
--     （tokens_granted == tokens_consumed + Σactive.remaining + discarded_tokens）。
-- ============================================================
local ngx_now = ngx.now
local ngx_worker_id = ngx.worker.id

local redis_mod = require "kong.plugins.rate-limit-advanced.lib.redis"

local _M = {}

-- ------------------------------------------------------------
-- Worker 级状态
--   pools[pool_key] = { active = {lease_obj,...}   可消费集合（方案 B 下 ≤1）
--                       last_used = 秒            TAKE/登记时一次赋值
--                       max_age  = 毫秒           首次 GRANT 的配置快照（=2×window）}
--   lease_obj = { lease_id, pool_key, granted, remaining, consumed,
--                 created_at(秒), state }  -- ACTIVE | CLOSED | EXPIRED
--   inflight[pool_key] = true                    单在途 GRANT 标志
--   终态对象（CLOSED/EXPIRED）立即解除引用，由 GC 回收；历史由计数器承载。
--   不变量：remaining + consumed = granted；0 ≤ remaining ≤ granted；
--           每对象至多在 active 出现一次；#active ≤ 1（方案 B 上界）。
-- ------------------------------------------------------------
_M._pools = {}
_M._inflight = {}
_M._pool_count = 0

-- MAX_POOLS：每 Worker Pool 数上限（关口二冻结：10000；测试可覆写）
_M.MAX_POOLS = 10000

-- 进程内生命周期计数（历史统计；number 自身有界）
_M._counters = {
  leases = 0, tokens_granted = 0, tokens_consumed = 0, closed = 0,
  expired = 0, evicted = 0, discarded_tokens = 0,
}

-- GRANT 路径惰性清扫 / Timer 每次处理的数量上限（冻结：32 / 64）
local SWEEP_CAP = 32
local TIMER_POOL_CAP = 64

-- ------------------------------------------------------------
-- lease_id 生成（不变）
-- ------------------------------------------------------------
local lease_seq = 0

local function host_name()
  local ok, v = pcall(function() return ngx.var.hostname end)
  if ok and type(v) == "string" and v ~= "" then
    return v
  end
  return os.getenv("HOSTNAME") or "unknown"
end

local cached_host
local seeded = false
local function ensure_random_seed()
  if seeded then
    return
  end
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

-- ------------------------------------------------------------
-- 过期判定与摘除（唯一入口；非 yield 片段）
-- 单位约定（冻结）：created_at / ngx.now() 秒；pool.max_age 毫秒。
-- ------------------------------------------------------------
local function is_expired(l, pool, now)
  return pool.max_age ~= nil
     and (l.created_at + pool.max_age / 1000) < now
end

-- discarded 只计一次的机制保证：state 先翻转、随即移出 active、计数同片段完成。
-- 任何路径（TAKE / GRANT 清扫 / Timer）摘除都必须经此函数。
local function expire_lease_at(pool, i)
  local l = pool.active[i]
  l.state = "EXPIRED"
  _M._counters.discarded_tokens = _M._counters.discarded_tokens + l.remaining
  _M._counters.expired = _M._counters.expired + 1
  table.remove(pool.active, i)
end

-- ------------------------------------------------------------
-- 登记一个已授予的 Lease。
-- 方案 B 上界：pool 已有 ACTIVE Lease ⇒ 拒绝（生产路径不可达；
-- 触发即说明在途闸门失效，按 uncertain 损失处理，方向保守）。
-- max_age_ms：该 Pool 首次 GRANT 的配置快照（= 2×window 毫秒）；仅首次生效。
-- @return lease 对象，或 nil, err（参数非法 / pool busy）
-- ------------------------------------------------------------
function _M.register(pool_key, lease_id, granted, created_at, max_age_ms)
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

  local pool = _M._pools[pool_key]
  if pool and #pool.active > 0 then
    return nil, "pool has active lease: " .. pool_key
  end
  if not pool then
    pool = { active = {}, last_used = nil, max_age = nil }
    _M._pools[pool_key] = pool
    _M._pool_count = _M._pool_count + 1
  end
  if pool.max_age == nil and max_age_ms ~= nil then
    if type(max_age_ms) ~= "number" or max_age_ms ~= max_age_ms
       or max_age_ms <= 0 or max_age_ms >= 2^53 then
      return nil, "max_age_ms must be a positive number: " .. tostring(max_age_ms)
    end
    pool.max_age = max_age_ms
  end

  local lease = {
    lease_id   = lease_id,
    pool_key   = pool_key,
    granted    = granted,
    remaining  = granted,          -- remaining + consumed = granted（守恒起点）
    consumed   = 0,
    created_at = created_at or ngx_now(),
    state      = "ACTIVE",
  }
  pool.active[#pool.active + 1] = lease
  pool.last_used = lease.created_at
  _M._counters.leases = _M._counters.leases + 1
  _M._counters.tokens_granted = _M._counters.tokens_granted + granted
  return lease
end

-- ------------------------------------------------------------
-- TAKE：原子消耗 1 个本地库存令牌。
-- 整体为非 yield 同步片段：ngx.now() 非 yield 点；无 cosocket / ngx.sleep。
-- 热路径：last_used 一次赋值 + 至多 1 个候选的过期比较（方案 B 上界 ⇒ 严格 O(1)）。
-- 候选过期 ⇒ expire_lease_at 摘除（discarded 一次计数）后继续；无候选 ⇒ NEED_GRANT。
-- @return true, remaining(扣减后), lease_id | false, "NEED_GRANT"
-- ------------------------------------------------------------
function _M.take(pool_key)
  local pool = _M._pools[pool_key]
  if not pool then
    return false, "NEED_GRANT"
  end

  local now = ngx_now()
  pool.last_used = now             -- TAKE 全路径唯一写点（一次赋值）
  local active = pool.active
  local i = 1
  while i <= #active do
    local l = active[i]
    if l.state ~= "ACTIVE" then
      table.remove(active, i)      -- 防御：active 集合内不应出现非 ACTIVE
    elseif is_expired(l, pool, now) then
      expire_lease_at(pool, i)
    else
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
-- GRANT 结果分类（不变，D4 四分类；纯函数）。
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
-- GRANT 路径惰性清扫：摘除当前 Pool 内已过期 Lease（上限 32/次）。
-- 由 grant() 在传输层调用前执行；纯 table 操作，非 yield。
-- ------------------------------------------------------------
function _M.sweep_pool(pool_key, cap)
  local pool = _M._pools[pool_key]
  if not pool then
    return 0
  end
  cap = cap or SWEEP_CAP
  local now = ngx_now()
  local removed = 0
  local i = 1
  while i <= #pool.active and removed < cap do
    local l = pool.active[i]
    if l.state ~= "ACTIVE" then
      table.remove(pool.active, i)
    elseif is_expired(l, pool, now) then
      expire_lease_at(pool, i)
      removed = removed + 1
    else
      i = i + 1
    end
  end
  return removed
end

-- ------------------------------------------------------------
-- 单在途 GRANT 标志（方案 B）。置位/清除均在 grant() 内的非 yield 片段：
-- algorithm 层在调用 grant() 前先查 grant_in_flight()（检查与置位之间
-- 无 yield 点 ⇒ 协程调度保证原子），置位期间的并发请求降级直连。
-- ------------------------------------------------------------
function _M.grant_in_flight(pool_key)
  return _M._inflight[pool_key] == true
end

-- ------------------------------------------------------------
-- 申请一个 Lease。
--   * GRANT 前惰性清扫当前 Pool（冻结 §4）。
--   * max_age 快照 = bucket_ttl_ms（= 2×window 毫秒，与桶 TTL 同源）。
--   * 结果不明确 ⇒ 不重试、不登记（D4，不变）。
-- @return 同既有四分类约定
-- ------------------------------------------------------------
_M._transport = nil  -- 测试注入点；nil ⇒ redis_mod.grant_lease

function _M.grant(conf, pool_key, bucket_key, batch, lease_ttl_ms,
                   rate, capacity, bucket_ttl_ms)
  local transport = _M._transport or redis_mod.grant_lease
  local lease_id = _M.new_lease_id()

  _M.sweep_pool(pool_key)
  _M._inflight[pool_key] = true
  local parsed, err = transport(conf, bucket_key, lease_id, pool_key,
                                batch, lease_ttl_ms, rate, capacity, bucket_ttl_ms)
  local class, data = _M.classify_grant(parsed, err)
  _M._inflight[pool_key] = nil     -- 清除与 classify/register 之间无 yield 点

  if class == "success" then
    local lease, rerr = _M.register(pool_key, lease_id, data.granted, nil, bucket_ttl_ms)
    if not lease then
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
-- Pool 容量（MAX_POOLS，冻结：10000/Worker）。
-- 在途 GRANT 占用池位（关口三审查修复）：跨 Pool 并发 GRANT 各自通过
-- ensure_capacity 后才 register，若不预留，登记完成时 _pool_count 可超上限
-- ⇒ count + inflight 数 ≥ MAX 即视为达容量。
-- ensure_capacity：未达上限 ⇒ true；达上限 ⇒ 先淘汰无 ACTIVE Lease 且非
-- 在途的 Pool（≤64 个，零库存损失），仍满 ⇒ false（调用方降级 batch=1 直连）。
-- ------------------------------------------------------------
function _M.pool_count()
  return _M._pool_count
end

local function inflight_count()
  local n = 0
  for _, v in pairs(_M._inflight) do
    if v == true then
      n = n + 1
    end
  end
  return n
end

function _M.ensure_capacity()
  if _M._pool_count + inflight_count() < _M.MAX_POOLS then
    return true
  end
  _M.evict_idle_pools(TIMER_POOL_CAP)
  return _M._pool_count + inflight_count() < _M.MAX_POOLS
end

-- 只淘汰没有 ACTIVE Lease 的 Pool（冻结：不驱逐含 ACTIVE Lease 的 Pool）；
-- 并跳过在途 GRANT 的 Pool（关口三审查修复：inflight Pool 的 GRANT 返回后
-- register 会重建 Pool ⇒ _pool_count 超 MAX_POOLS）。
-- 纯 table 操作，非 yield；键集合扫描 O(P) 有界于 MAX_POOLS。
function _M.evict_idle_pools(cap)
  cap = cap or TIMER_POOL_CAP
  local removed = 0
  for key, pool in pairs(_M._pools) do
    if removed >= cap then
      break
    end
    if _M._inflight[key] ~= true and #pool.active == 0 then
      _M._pools[key] = nil
      _M._pool_count = _M._pool_count - 1
      _M._counters.evicted = _M._counters.evicted + 1
      removed = removed + 1
    end
  end
  return removed
end

-- ------------------------------------------------------------
-- Timer 兜底清扫（init_worker 每 60s 调一次；可被单测直接调用）。
-- 只处理"空闲候选"：last_used 距今 ≥ max_age/1000（秒口径）的 Pool；
-- 每 tick 处理 ≤ cap 个（冻结 64）。对空闲 Pool：先摘除其中已过期 Lease
--（经 expire_lease_at，discarded 一次计数），active 清空后整池删除。
-- 键集合扫描 O(P) 有界于 MAX_POOLS；纯 table 操作，非 yield。
-- @return 本次删除的 Pool 数
-- ------------------------------------------------------------
function _M.timer_sweep_once(cap)
  cap = cap or TIMER_POOL_CAP
  local now = ngx_now()
  local evicted = 0
  for key, pool in pairs(_M._pools) do
    if evicted >= cap then
      break
    end
    local max_age_s = pool.max_age and pool.max_age / 1000
    if max_age_s then
      local idle_for = now - (pool.last_used or 0)
      if idle_for >= max_age_s and _M._inflight[key] ~= true then
        -- 关口三审查修复：在途 GRANT 的 Pool 跳过（GRANT 返回后 register
        -- 会重建 Pool ⇒ _pool_count 超 MAX_POOLS）。
        local i = 1
        while i <= #pool.active do
          local l = pool.active[i]
          if l.state ~= "ACTIVE" then
            table.remove(pool.active, i)
          elseif is_expired(l, pool, now) then
            expire_lease_at(pool, i)
          else
            i = i + 1
          end
        end
        if #pool.active == 0 then
          _M._pools[key] = nil
          _M._pool_count = _M._pool_count - 1
          _M._counters.evicted = _M._counters.evicted + 1
          evicted = evicted + 1
        end
      end
    end
  end
  return evicted
end

-- ------------------------------------------------------------
-- init_worker 兜底 Timer（冻结：60s 间隔）。模块级防重复注册
--（多插件实例共享同一 Worker VM）；resty 单测环境无 ngx.timer ⇒ 跳过。
-- ------------------------------------------------------------
local timer_started = false

function _M.start_sweep_timer()
  if timer_started then
    return true
  end
  timer_started = true
  if not (ngx and ngx.timer and ngx.timer.every) then
    return false, "ngx.timer.every unavailable"
  end
  local ok, err = pcall(ngx.timer.every, 60, function(premature)
    if premature then
      return
    end
    local exiting = false
    pcall(function() exiting = ngx.worker.exiting() end)
    if exiting then
      return
    end
    pcall(_M.timer_sweep_once, TIMER_POOL_CAP)
  end)
  if not ok then
    timer_started = false
    return nil, "timer create failed: " .. tostring(err)
  end
  return true
end

-- ------------------------------------------------------------
-- D8 指标（整改口径）：outstanding = local_remaining；
-- discarded_tokens 由 expire_lease_at 维护；恒等式见 invariants()。
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
    leases           = c.leases,
    granted          = c.tokens_granted,
    consumed         = c.tokens_consumed,
    closed           = c.closed,
    expired          = c.expired,
    evicted          = c.evicted,
    discarded_tokens = c.discarded_tokens,
    active           = active,
    local_remaining  = remaining,
    outstanding      = remaining,
    pools            = _M._pool_count,
  }
end

-- ------------------------------------------------------------
-- 结构不变量校验（整改口径）：
--   * 每 Pool #active ≤ 1（方案 B 上界）
--   * active 对象：state=ACTIVE、0 < remaining ≤ granted、守恒
--   * 全局账目：tokens_granted == tokens_consumed + Σactive.remaining
--               + discarded_tokens
--   * 租约数量闭环：leases == closed + expired + active_total
-- @return true | false, reason
-- ------------------------------------------------------------
function _M.invariants()
  local n_active = 0
  local sum_remaining = 0
  for _, pool in pairs(_M._pools) do
    if #pool.active > 1 then
      return false, "active lease bound broken: " .. tostring(#pool.active)
    end
    local seen = {}
    for i = 1, #pool.active do
      local l = pool.active[i]
      if seen[l] then
        return false, "duplicate object in active set"
      end
      seen[l] = true
      if l.state ~= "ACTIVE" then
        return false, "active contains non-ACTIVE lease: " .. l.lease_id
      end
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
      n_active = n_active + 1
      sum_remaining = sum_remaining + l.remaining
    end
  end
  local c = _M._counters
  -- 容量上限不变量（关口三审查补充）：生产路径每次 register 前均经
  -- ensure_capacity 放行 ⇒ count 不会超 MAX_POOLS（测试直改 MAX 属人工态）
  if _M._pool_count > _M.MAX_POOLS then
    return false, "pool count exceeds MAX_POOLS: " .. _M._pool_count
      .. " > " .. _M.MAX_POOLS
  end
  -- 终态对象已释放，逐对象求和仅覆盖 active；全局口径以恒等式与数量闭环校验：
  --   granted = consumed + outstanding + discarded（逐对象守恒在摘除瞬间转移）
  if c.tokens_granted ~= c.tokens_consumed + sum_remaining + c.discarded_tokens then
    return false, "accounting identity broken: granted=" .. c.tokens_granted
      .. " consumed=" .. c.tokens_consumed
      .. " outstanding=" .. sum_remaining
      .. " discarded=" .. c.discarded_tokens
  end
  if c.leases ~= c.closed + c.expired + n_active then
    return false, "lease count not closed: leases=" .. c.leases
      .. " closed=" .. c.closed .. " expired=" .. c.expired
      .. " active=" .. n_active
  end
  return true
end

-- ------------------------------------------------------------
-- 清空 Worker 级状态（仅测试使用：等价于 Worker 重启）。
-- ------------------------------------------------------------
function _M.reset()
  _M._pools = {}
  _M._inflight = {}
  _M._pool_count = 0
  _M._counters = {
    leases = 0, tokens_granted = 0, tokens_consumed = 0, closed = 0,
    expired = 0, evicted = 0, discarded_tokens = 0,
  }
  lease_seq = 0
end

return _M
