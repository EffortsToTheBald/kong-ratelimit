-- ============================================================
-- lease-concurrent-grant-probe.lua —— 关口一并发 GRANT 探针（只读生产代码）
--
-- 诚实性声明（结论解读必读）：
--   本探针用 Lua 协程 + 调度循环模拟并发：协程只在 lease._transport 注入的
--   传输层内 yield（coroutine.yield），yield 点位置与真实 cosocket 读写
--   yield 点一致；TAKE/登记段保持非 yield。但调度器是普通 Lua 循环，
--   不是 OpenResty 的真实 cosocket/事件调度 ⇒ 本探针结果
--   **不得写成真实 OpenResty 并发验证**（真实环境证据：test/concurrent-lease-e2e.sh
--   实测 270 并发，标记为对照；本探针结论标 NOT VERIFIED 待真实 E2E 复核）。
--
-- 量化口径：
--   * 在途 GRANT（inflight）= 已进入 transport、尚未拿到响应的 GRANT 调用数
--   * 登记 Lease 数 = 该 pool 最终 pool.leases 长度（= confirmed_granted 的笔数）
--   * confirmed_granted = Σgranted（成功并登记的授权令牌）
--   * consumed = tokens_consumed；outstanding = local_remaining
--   * 账目恒等式检查：confirmed_granted == consumed + outstanding（discarded=0）
--   * uncertain_lost：本探针 transport 恒定成功，恒为 0
-- 运行：docker compose cp 进 kong1 后 resty 执行。
-- ============================================================
local algorithm = require("kong.plugins.rate-limit-advanced.lib.algorithm")
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")
local redis_mod = require("kong.plugins.rate-limit-advanced.lib.redis")

-- ---- kong 全局 stub（与 algorithm-lease-unit.lua 同手法）----
kong = {
    log = { notice = function() end, err = function() end,
            warn = function() end, debug = function() end },
}

-- 关口三后：并发请求在单在途 GRANT 置位期间走 batch=1 直连（redis_mod.grant）
-- ⇒ 探针必须同时计数直连 stub，否则直连会触到真 cosocket。
local direct_calls = 0
local orig_grant = redis_mod.grant
redis_mod.grant = function(conf, key, want, ttl_ms, rate, burst)
    direct_calls = direct_calls + 1
    return { granted = 1, tokens = 99.5, wait = 0 }
end

local conf = {
    limit = 1000,
    window = 60,
    burst = 1000,
    batch = 10,          -- 显式 batch，禁用 auto
    namespace = "probe",
    redis = { key_prefix = "kong:rl" },
}

local PK = "kong:rl:{probe:ip=10.0.0.1}"

-- ---- 传输层注入：会 yield 的"慢 Redis"假传输层 ----
local inflight, max_inflight = 0, 0
local grant_calls = 0
local TICKS = tonumber(os.getenv("GRANT_TICKS") or 5)

local function slow_transport(conf, bucket_key, lease_id, pool_key,
                              batch, lease_ttl_ms, rate, capacity, bucket_ttl_ms)
    grant_calls = grant_calls + 1
    inflight = inflight + 1
    if inflight > max_inflight then max_inflight = inflight end
    for _ = 1, TICKS do
        coroutine.yield("grant_inflight")   -- 模拟 cosocket 读/写 yield 点
    end
    inflight = inflight - 1
    -- 与真实 GRANT_LEASE 成功返回同构：granted=batch 全量授予
    return { granted = batch, tokens = 0.5, wait = 0 }
end

local function run(label, n, spawn_every)
    lease.reset()
    lease._transport = slow_transport
    grant_calls, inflight, max_inflight = 0, 0, 0

    local cos = {}
    for i = 1, n do
        cos[i] = coroutine.create(function()
            return algorithm.check_lease(conf, PK)
        end)
    end

    -- 调度循环：round-robin；spawn_every>1 时按间隔错峰启动（模拟到达率）
    local live, step = n, 0
    local spawned = {}
    for i = 1, n do spawned[i] = false end
    while live > 0 do
        step = step + 1
        -- 每 step 启动 spawn_every 个新协程（burst 场景 spawn_every=n 即全量启动）
        local to_spawn = spawn_every
        for i = 1, n do
            if to_spawn == 0 then break end
            if not spawned[i] then
                spawned[i] = true
                to_spawn = to_spawn - 1
            end
        end
        for i = 1, n do
            if spawned[i] and coroutine.status(cos[i]) ~= "dead" then
                local ok, res, err = coroutine.resume(cos[i])
                if ok and res and res.allowed == false then
                    -- granted=0：本探针恒成功，不应到达
                    print("UNEXPECTED 429 at " .. i)
                elseif not ok and type(err) == "string" then
                    print("UNEXPECTED error at " .. i .. ": " .. err)
                end
                if coroutine.status(cos[i]) == "dead" then
                    live = live - 1
                end
            end
        end
    end

    local pool = lease._pools[PK]
    local st = lease.stats()
    local n_leases = pool and #pool.active or 0
    local confirmed = st.granted
    local id_ok = (confirmed == st.consumed + st.local_remaining)
    local bound_ok = (n_leases <= 1)

    print(string.format(
        "[%s] N=%d spawn_every=%d ticks=%d grant_calls=%d direct_calls=%d max_inflight=%d leases=%d(<=1:%s) confirmed_granted=%d consumed=%d outstanding=%d discarded=0 identity_ok=%s",
        label, n, spawn_every, TICKS, grant_calls, direct_calls, max_inflight,
        n_leases, tostring(bound_ok), confirmed, st.consumed,
        st.local_remaining, tostring(id_ok)))
    print(string.format(
        "[%s] 账目: confirmed_granted(%d) = consumed(%d) + outstanding(%d) + discarded(0)；直连授权 %d 笔不入 Lease 账目（batch=1 既有口径）；uncertain_lost=0",
        label, confirmed, st.consumed, st.local_remaining, direct_calls))

    lease._transport = nil
    direct_calls = 0
end

-- 场景 1：同时到达（burst）——所有请求在第一批调度即全部进入 transport
for _, n in ipairs({ 2, 10, 50, 100 }) do
    run("burst", n, n)
end

-- 场景 2：错峰到达——每调度步启动 1 个新请求（模拟到达率 vs RTT 竞争）
run("steady", 100, 1)

lease.reset()
print("NOTE: Lua 协程交错模型（yield 点=transport 内部）；真实 OpenResty cosocket 并发验证 NOT VERIFIED")
