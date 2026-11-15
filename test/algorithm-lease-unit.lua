-- ============================================================
-- algorithm-lease-unit.lua —— 6.1 接线单测：三模式行为矩阵（resty）
--
-- 覆盖（用户验收测试 §五 1/2/3/4/5/6/9/13 的单测层）：
--   A. batch=1 完全不触 Lease（redis grant 被调、transport 零调用、零登记）
--   B. batch>1 首请求触发 GRANT_LEASE：参数正确、登记后恰好消费 1
--   C. 后续请求本地 TAKE，不重复访问 Redis
--   D. 库存耗尽 CLOSED 摘除 + 再申请新 Lease（多 Lease 并存不覆盖）
--   E. GRANT 部分授予：按实际 granted 登记、不重复消费
--   F. granted=0 ⇒ 429（retry_after=wait 透传、不登记）
--   G. explicit_error ⇒ 故障分支（nil, err、不登记、不重试）
--   H. uncertain ⇒ 故障分支（nil, err、不登记、不重试）
--   I. 配置变化 ⇒ pool_key 指纹隔离（不同 key 不共用库存）
--   J. 多规则 ⇒ GRANT_MULTI、不触 Lease
--
-- 复用 Phase 4 基建：lease._transport 注入 + redis_mod monkeypatch（无新依赖）。
-- ============================================================
local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

local algorithm = require("kong.plugins.rate-limit-advanced.lib.algorithm")
local redis_mod = require("kong.plugins.rate-limit-advanced.lib.redis")
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

-- ---- kong 全局 stub（build_key 的 ip 维度 + 日志） ----
kong = {
    log = { notice = function() end, err = function() end, warn = function() end, debug = function() end },
    client = { get_forwarded_ip = function() return "10.0.0.1" end,
               get_ip = function() return "10.0.0.1" end,
               get_consumer = function() return nil end },
    request = { get_path = function() return "/" end,
                get_method = function() return "GET" end,
                get_header = function() return nil end },
    router = { get_route = function() return nil end,
               get_service = function() return nil end },
}

-- ---- spies ----
local calls = { grant = 0, grant_multi = 0, transport = 0, warn = 0 }
local grant_ret       -- batch=1 stub 返回
local grant_multi_ret -- 多规则 stub 返回
local transport_ret   -- GRANT_LEASE stub 返回 {parsed} 或 nil, err
local transport_err   -- GRANT_LEASE stub 第二返回值（err）

local orig_grant, orig_grant_multi = redis_mod.grant, redis_mod.grant_multi
redis_mod.grant = function(conf, key, batch, ttl_ms, rate, burst)
    calls.grant = calls.grant + 1
    return grant_ret
end
redis_mod.grant_multi = function(conf, keys, rates, bursts, ttls)
    calls.grant_multi = calls.grant_multi + 1
    return grant_multi_ret
end

local last_args
lease._transport = function(conf, bucket_key, lease_id, pool_key, batch,
                            lease_ttl_ms, rate, capacity, bucket_ttl_ms)
    calls.transport = calls.transport + 1
    last_args = { bucket_key = bucket_key, lease_id = lease_id,
                  pool_key = pool_key, batch = batch, ttl = lease_ttl_ms,
                  rate = rate, capacity = capacity, bucket_ttl = bucket_ttl_ms }
    return transport_ret, transport_err
end

-- kong stub 补充：warn 计数（pool_cap_degraded 取证）
local _warn = kong.log.warn
kong.log.warn = function(...) calls.warn = calls.warn + 1 end

local function base_conf()
    return {
        namespace = "rl", limit = 100, window = 3600, burst = nil,
        batch = 20, limit_by = { "ip" }, fault_tolerant = false,
        redis = { key_prefix = "kong:rl" },
    }
end

lease.reset()
grant_ret = { granted = 1, tokens = 99, wait = 0 }

-- ============================================================
-- A. batch=1：完全不触 Lease
-- ============================================================
do
    local conf = base_conf(); conf.batch = 1
    local key = algorithm.build_key(conf)
    local d = algorithm.check(conf, key)
    ok("A-batch1-uses-grant", d ~= nil and d.allowed == true
       and calls.grant == 1, tostring(d and d.allowed) .. "/" .. calls.grant)
    ok("A-batch1-zero-lease",
       calls.transport == 0 and lease.stats().leases == 0,
       "transport=" .. calls.transport .. " leases=" .. lease.stats().leases)
end

-- ============================================================
-- B. batch>1 首请求：GRANT_LEASE + 登记后恰好消费 1
-- ============================================================
do
    lease.reset(); calls.grant, calls.transport = 0, 0
    transport_ret = { granted = 10, tokens = 90, wait = 0 }  -- granted=min(batch, floor(tokens))
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    local d = algorithm.check(conf, key)
    ok("B-first-grant-allowed", d ~= nil and d.allowed == true
       and d.remaining == 9, tostring(d and d.remaining))
    ok("B-transport-args", calls.transport == 1
       and last_args.pool_key == key and last_args.bucket_key == key
       and last_args.batch == 20 and last_args.ttl == 3600000
       and math.abs(last_args.rate - 100/3600) < 1e-9
       and last_args.bucket_ttl == 3600 * 2 * 1000,
       "pool=" .. tostring(last_args.pool_key) .. " batch=" .. last_args.batch)
    local st = lease.stats()
    ok("B-register-consume-one", st.leases == 1 and st.local_remaining == 9
       and st.consumed == 1 and st.granted == 10,
       "leases=" .. st.leases .. " rem=" .. st.local_remaining)
    ok("B-no-repeat-redis", calls.grant == 0,
       "batch>1 不得走 batch=1 的 redis grant: " .. calls.grant)
end

-- ============================================================
-- C. 后续请求本地 TAKE，不重复访问 Redis
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    calls.transport = 0
    local d = algorithm.check(conf, key)
    local st = lease.stats()
    ok("C-local-take", d ~= nil and d.allowed == true and d.remaining == 8
       and calls.transport == 0 and st.leases == 1,
       "rem=" .. tostring(d and d.remaining) .. " transport=" .. calls.transport)
end

-- ============================================================
-- D. 耗尽 ⇒ CLOSED 摘除 + 再申请新 Lease（并存不覆盖）
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    -- 再消费 8 个耗尽当前 Lease（remaining 8→0）
    for _ = 1, 8 do algorithm.check(conf, key) end
    local st = lease.stats()
    ok("D-exhausted-closed", st.leases == 1 and st.closed == 1
       and st.local_remaining == 0,
       "leases=" .. st.leases .. " closed=" .. st.closed)
    -- 下一次请求触发新 Lease；返回 granted=5（部分授予，兼覆盖 E）
    calls.transport = 0
    transport_ret = { granted = 5, tokens = 80, wait = 0.5 }
    local d = algorithm.check(conf, key)
    st = lease.stats()
    ok("D-regrant-partial", d ~= nil and d.allowed == true and d.remaining == 4
       and calls.transport == 1 and st.leases == 2 and st.closed == 1
       and st.active == 1 and st.local_remaining == 4,
       "rem=" .. tostring(d and d.remaining) .. " leases=" .. st.leases)
    -- 关口三改造：终态对象即释放（诊断表取消）⇒ 原"闭 Lease 对象仍在全量表"
    -- 断言改为计数器闭环（closed=1、租约数量闭环、恒等式成立）
    ok("D-closed-counted",
       st.leases == st.closed + st.expired + st.active
       and st.granted == st.consumed + st.local_remaining + st.discarded_tokens
       and #lease._pools[key].active == 1
       and lease._pools[key].active[1].lease_id ~= nil,
       "leases=" .. st.leases .. " closed=" .. st.closed
       .. " active=" .. #lease._pools[key].active)
end

-- ============================================================
-- F. granted=0 ⇒ 429（wait 透传，不登记）
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    lease.reset(); calls.transport = 0
    transport_ret = { granted = 0, tokens = 0.5, wait = 0.7 }
    local d = algorithm.check(conf, key)
    ok("F-insufficient-429", d ~= nil and d.allowed == false
       and d.retry_after == 0.7 and d.remaining == 0
       and calls.transport == 1 and lease.stats().leases == 0,
       tostring(d and d.retry_after) .. "/" .. calls.transport)
    -- wait<=0 ⇒ 兜底 1（既有契约）
    transport_ret = { granted = 0, tokens = 0, wait = 0 }
    local d2 = algorithm.check(conf, key)
    ok("F-insufficient-wait-floor", d2.allowed == false and d2.retry_after == 1,
       tostring(d2.retry_after))
end

-- ============================================================
-- G/H. 显式错误与不确定 ⇒ 故障分支（nil, err、不登记、不重试）
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    lease.reset(); calls.transport = 0

    transport_ret, transport_err = nil, "LEASE_EXISTS: lease already exists"
    local d, err = algorithm.check(conf, key)
    ok("G-explicit-fault", d == nil and type(err) == "string" and err ~= ""
       and calls.transport == 1 and lease.stats().leases == 0,
       tostring(d) .. "/" .. tostring(err) .. "/" .. calls.transport)

    calls.transport = 0
    transport_ret, transport_err = nil, "timeout"
    local d2, err2 = algorithm.check(conf, key)
    ok("H-uncertain-fault", d2 == nil and type(err2) == "string" and err2 ~= ""
       and calls.transport == 1 and lease.stats().leases == 0,
       tostring(d2) .. "/" .. tostring(err2) .. "/" .. calls.transport)
end

-- ============================================================
-- I. 配置变化 ⇒ pool_key 指纹隔离
-- ============================================================
do
    lease.reset()
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    local c1 = base_conf()
    local k1 = algorithm.build_key(c1)
    algorithm.check(c1, k1)
    local c2 = base_conf(); c2.limit = 200   -- 指纹变化 ⇒ 新 key
    local k2 = algorithm.build_key(c2)
    ok("I-fingerprint-isolates", k1 ~= k2 and lease._pools[k2] == nil
       and #lease._pools[k1].active == 1,
       k1 .. " vs " .. k2)
    -- header 维度变化同样隔离（指纹输入含 limit_by/header_name）
    local c3 = base_conf(); c3.limit_by = { "ip", "header" }; c3.header_name = "X-K"
    local k3 = algorithm.build_key(c3)
    ok("I-dim-change-isolates", k3 ~= k1, k1 .. " vs " .. k3)
end

-- ============================================================
-- J. 多规则 ⇒ GRANT_MULTI、不触 Lease
-- ============================================================
do
    lease.reset(); calls.grant, calls.grant_multi, calls.transport = 0, 0, 0
    grant_multi_ret = { ok = 1, buckets = { { tokens = 99, wait = 0 }, { tokens = 99, wait = 0 } } }
    local conf = {
        namespace = "rl", fault_tolerant = false,
        rules = { { limit = 100, window = 3600, limit_by = { "ip" } },
                  { limit = 50,  window = 3600, limit_by = { "ip" } } },
        redis = { key_prefix = "kong:rl" },
    }
    algorithm.build_group_keys(conf)
    local d = algorithm.check_multi(conf)
    ok("J-multi-uses-grant-multi", d ~= nil and d.allowed == true
       and calls.grant_multi == 1 and calls.transport == 0
       and lease.stats().leases == 0,
       tostring(d and d.allowed) .. "/multi=" .. calls.grant_multi)
end

-- ============================================================
-- K/L/M. 关口三新增：MAX_POOLS 降级 / 单在途降级 / 并发 burst（协程模型）
-- ============================================================
do -- K：MAX_POOLS 达上限且无可淘汰空池 ⇒ pool_cap 降级直连（不 429/不 503、不登记）
    lease.reset()
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 1
    local c1 = base_conf()
    local k1 = algorithm.build_key(c1)
    algorithm.check(c1, k1)                        -- k1 建 Pool（ACTIVE）
    local c2 = base_conf(); c2.limit = 200         -- 不同 key ⇒ 第二个 Pool
    local k2 = algorithm.build_key(c2)
    calls.grant, calls.transport, calls.warn = 0, 0, 0
    local d = algorithm.check(c2, k2)              -- NEED_GRANT ⇒ 达上限 ⇒ 降级
    ok("K-poolcap-direct-degrade",
       d ~= nil and d.allowed == true and d.remaining == 0
       and calls.grant == 1 and calls.transport == 0
       and calls.warn == 1 and lease.stats().leases == 1,
       "d=" .. tostring(d and d.allowed) .. " grant=" .. calls.grant
       .. " warn=" .. calls.warn .. " leases=" .. lease.stats().leases)
    -- k1 池耗尽成空池后，ensure_capacity 淘汰空池恢复容量（零库存损失）
    local k1pool = lease._pools[k1]
    for _ = 1, 10 do lease.take(k1) end            -- 耗尽 k1 的 Lease
    lease.MAX_POOLS = 1
    local d2 = algorithm.check(c2, k2)             -- k1 空池被淘汰 ⇒ k2 正常 GRANT
    ok("K-poolcap-evict-then-grant",
       d2 ~= nil and d2.allowed == true and lease._pools[k1] == nil
       and lease._pools[k2] ~= nil and lease.stats().evicted == 1
       and calls.transport == 1,
       "d2=" .. tostring(d2 and d2.allowed) .. " transport=" .. calls.transport)
    lease.MAX_POOLS = saved
end

do -- L：单在途标志置位 ⇒ 并发请求降级直连（不登记，方案 B）
    lease.reset()
    calls.grant, calls.transport = 0, 0
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    lease._inflight[key] = true                    -- 模拟在途 GRANT（不 yield 场景）
    local d = algorithm.check(conf, key)
    lease._inflight[key] = nil
    ok("L-inflight-direct-degrade",
       d ~= nil and d.allowed == true and d.remaining == 0
       and calls.grant == 1 and calls.transport == 0
       and lease.stats().leases == 0,
       "d=" .. tostring(d and d.allowed) .. " grant=" .. calls.grant)
    -- 直连请求不进 Lease 账目：恒等式与数量闭环仍成立
    ok("L-direct-out-of-ledger", lease.invariants())
end

do -- M：并发 burst（Lua 协程交错模型，yield 点=transport 内部；非真实 OpenResty 验证）
    lease.reset()
    calls.grant, calls.transport = 0, 0
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    transport_ret = { granted = 10, tokens = 90, wait = 0 }

    local N = 20
    local TICKS = 5
    lease._transport = function(...)
        coroutine.yield("grant_inflight")          -- 模拟 cosocket yield ×TICKS
        coroutine.yield("grant_inflight")
        coroutine.yield("grant_inflight")
        coroutine.yield("grant_inflight")
        coroutine.yield("grant_inflight")
        calls.transport = calls.transport + 1
        return transport_ret, transport_err
    end

    local cos = {}
    for i = 1, N do
        cos[i] = coroutine.create(function()
            return algorithm.check(conf, key)
        end)
    end
    local live, decisions = N, {}
    while live > 0 do
        for i = 1, N do
            if coroutine.status(cos[i]) ~= "dead" then
                local okr, d = coroutine.resume(cos[i])
                if not okr then
                    decisions[#decisions + 1] = { err = tostring(d) }
                    live = live - 1
                elseif coroutine.status(cos[i]) == "dead" then
                    decisions[#decisions + 1] = d
                    live = live - 1
                end
            end
        end
    end
    lease._transport = nil

    local st = lease.stats()
    local all_allowed, n_direct_expected = true, true
    for i = 1, N do
        local d = decisions[i]
        if not (d and d.allowed == true) then all_allowed = false end
    end
    ok("M-concurrent-all-allowed", all_allowed,
       "allowed=" .. tostring(all_allowed))
    ok("M-single-inflight-grant",
       calls.transport == 1 and calls.grant == N - 1,
       "transport=" .. calls.transport .. " direct=" .. calls.grant)
    ok("M-active-bound-one",
       st.active == 1 and st.leases == 1 and st.local_remaining == 9,
       "active=" .. st.active .. " leases=" .. st.leases
       .. " rem=" .. st.local_remaining)
    ok("M-ledger-identity",
       st.granted == st.consumed + st.local_remaining + st.discarded_tokens
       and lease.invariants(),
       "g=" .. st.granted .. " c=" .. st.consumed .. " o=" .. st.local_remaining)
end

do -- N：确定性并发（关口三审查修复验证）——A 的 GRANT yield 期间 B 触发容量回收：
    -- A 不被回收、在途 GRANT 占用池位 ⇒ 最终 Pool 数量不超上限
    lease.reset()
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 2
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    local confA = base_conf()
    local keyA = algorithm.build_key(confA)

    -- 两阶段 stub：park=false 直返（纪元 1）；park=true 先 yield（模拟 cosocket 挂起）
    local transport_calls_N = 0
    local park = false
    lease._transport = function(...)
        transport_calls_N = transport_calls_N + 1
        if park then
            coroutine.yield("grant_inflight")
        end
        return transport_ret, transport_err
    end

    -- 纪元 1：A 正常 GRANT 建池（count=1 < MAX=2）后耗尽成空池
    local dA1 = algorithm.check(confA, keyA)
    for _ = 1, 10 do lease.take(keyA) end
    ok("N-epoch1-empty-pool",
       dA1 ~= nil and dA1.allowed == true and lease.pool_count() == 1
       and #lease._pools[keyA].active == 0,
       "count=" .. lease.pool_count())

    -- A 重新 GRANT：count(1) < MAX(2) ⇒ 不触发淘汰 ⇒ Pool A 存在、inflight 置位、挂起
    park = true
    local coA = coroutine.create(function()
        return algorithm.check(confA, keyA)
    end)
    coroutine.resume(coA)
    local poolA_ref = lease._pools[keyA]
    ok("N-parked-inflight",
       coroutine.status(coA) == "suspended"
       and lease.grant_in_flight(keyA) == true
       and poolA_ref ~= nil and #poolA_ref.active == 0,
       "status=" .. coroutine.status(coA)
       .. " inflight=" .. tostring(lease.grant_in_flight(keyA)))

    -- 直建空池 C（测试用 register 原语；count=2=MAX）
    local keyC = "kong:rl:{n:c:ip=10.0.0.1}"
    lease.register(keyC, "id-c", 5)
    for _ = 1, 5 do lease.take(keyC) end
    ok("N-pool-c-created", lease.pool_count() == 2, "count=" .. lease.pool_count())

    -- B 触发容量回收：count(2)+inflight(1) ≥ MAX(2) ⇒ 淘汰 C（跳过在途 A）⇒ 仍满 ⇒ 降级直连
    local confB = base_conf(); confB.limit = 200
    local keyB = algorithm.build_key(confB)
    calls.grant, calls.warn = 0, 0
    local dB = algorithm.check(confB, keyB)
    ok("N-b-degrade-and-evict-skip-inflight",
       dB ~= nil and dB.allowed == true and dB.remaining == 0
       and calls.grant == 1 and transport_calls_N == 2
       and lease._pools[keyC] == nil and lease._pools[keyA] == poolA_ref
       and lease.pool_count() == 1 and lease.stats().evicted == 1
       and calls.warn == 1,
       "grant=" .. calls.grant .. " transport=" .. transport_calls_N
       .. " count=" .. lease.pool_count()
       .. " evicted=" .. lease.stats().evicted)

    -- A 恢复：GRANT 返回 ⇒ register 复用原 Pool（不重建）⇒ 总数仍 ≤ 上限
    park = false
    local okr, dA2 = coroutine.resume(coA)
    lease._transport = nil
    local st = lease.stats()
    ok("N-register-reuses-pool",
       okr and dA2 ~= nil and dA2.allowed == true and dA2.remaining == 9
       and lease._pools[keyA] == poolA_ref
       and lease.pool_count() == 1
       and lease.pool_count() <= lease.MAX_POOLS,
       "dA2=" .. tostring(dA2 and dA2.allowed)
       .. " count=" .. lease.pool_count())
    ok("N-invariants-with-bound", lease.invariants(),
       tostring(lease.invariants()))
    ok("N-ledger-identity",
       st.granted == st.consumed + st.local_remaining + st.discarded_tokens,
       "g=" .. st.granted .. " c=" .. st.consumed
       .. " o=" .. st.local_remaining .. " d=" .. st.discarded_tokens)
    lease.MAX_POOLS = saved
end

redis_mod.grant, redis_mod.grant_multi = orig_grant, orig_grant_multi

print("===== 汇总: PASS=" .. pass .. " FAIL=" .. fail .. " =====")
if fail > 0 then os.exit(1) end
