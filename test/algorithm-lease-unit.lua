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
    log = { notice = function() end, err = function() end, warn = function() end },
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
local calls = { grant = 0, grant_multi = 0, transport = 0 }
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
    -- 旧 Lease 保留诊断记录：闭 Lease 对象仍在全量表中
    local pool = lease._pools[key]
    ok("D-closed-retained", #pool.leases == 2 and #pool.active == 1
       and pool.leases[1].state == "CLOSED" and pool.leases[1].remaining == 0
       and pool.leases[2].state == "ACTIVE",
       "leases=" .. #pool.leases .. " active=" .. #pool.active)
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

redis_mod.grant, redis_mod.grant_multi = orig_grant, orig_grant_multi

print("===== 汇总: PASS=" .. pass .. " FAIL=" .. fail .. " =====")
if fail > 0 then os.exit(1) end
