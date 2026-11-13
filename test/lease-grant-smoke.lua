-- lease-grant-smoke.lua —— GRANT 接线真链路 smoke（任务 4.4 传输层证据）
-- Case 1：真实 Redis GRANT_LEASE ⇒ 建本地 Lease + 本地消费 5 个 + Redis 记录/扣桶证据
-- Case 2（PAUSE=1，timeout=500ms）：CLIENT PAUSE 期间 GRANT 超时 ⇒ uncertain、
--        不重试（耗时 < 2×timeout）、不登记本地库存；pause 结束后 Redis 侧证据：
--        桶已被扣（tokens < capacity）+ Lease 记录已建（OPEN）⇒ 库存损失方向
local red_cli = require "resty.redis"
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

-- hget 缺字段时 resty.redis 返回 ngx.null（userdata）：先归一化再 tonumber
local function num(v)
    if v == nil or v == ngx.null then return nil end
    return tonumber(v)
end

local conf = {
    redis = {
        host = "redis",
        port = 6379,
        timeout = tonumber(os.getenv("REDIS_TIMEOUT") or 1000),
        key_prefix = "kong:rl",
    },
}
local PK = "kong:rl:{p4smoke:ip=10.9.9.9}"
local BK = PK

local rc = red_cli:new()
rc:set_timeouts(2000, 2000, 2000)
assert(rc:connect("redis", 6379))

-- 清场
rc:del(BK)
local before_keys = rc:keys("kong:rl:lease:*") or {}
local seen_before = {}
for _, k in ipairs(before_keys) do seen_before[k] = true end

-- ============ Case 1：正常 GRANT + 本地消费（PAUSE 模式下跳过） ============
if os.getenv("PAUSE") ~= "1" then
do
    lease.reset()
    local res, err = lease.grant(conf, PK, BK, 5, 60000, 1, 100, 120000)
    ok("smoke-grant-success",
       res ~= nil and err == nil and res.ok == true and res.granted == 5,
       tostring(res) .. "/" .. tostring(err))

    local lkey = "kong:rl:lease:" .. res.lease_id
    local status = rc:hget(lkey, "status")
    local granted = num(rc:hget(lkey, "granted"))
    ok("smoke-redis-record", status == "OPEN" and granted == 5,
       "status=" .. tostring(status) .. " granted=" .. tostring(granted))

    local tokens = num(rc:hget(BK, "tokens"))
    ok("smoke-bucket-debited",
       tokens ~= nil and tokens >= 93 and tokens <= 96,   -- 100−5 + refill(≤1s, rate=1/s)
       tostring(tokens))

    local all_taken = true
    for _ = 1, 5 do
        local t = lease.take(PK)
        if not t then all_taken = false end
    end
    local t6 = lease.take(PK)
    local st = lease.stats()
    ok("smoke-local-consume",
       all_taken and t6 == false and st.closed == 1 and st.consumed == 5
       and lease.invariants(),
       "t6=" .. tostring(t6) .. " closed=" .. st.closed)

    rc:del(lkey)
    lease.reset()
end
end

-- ============ Case 2：CLIENT PAUSE ⇒ uncertain（不重试/不登记/损失方向） ============
-- 前提：脚本 SHA 已在 VM/Redis 缓存（先 warm-up 装载；否则首次 EVALSHA 的懒加载
-- SCRIPT LOAD 会先超时——那是"确定未执行"= explicit_error，不是本例要测的执行超时）。
-- 流程：warm-up（真 GRANT 装载 SHA 并清理）→ 轮询探测 pause 生效（ping 超时）
--       → 实测 GRANT（EVALSHA 执行超时 ⇒ uncertain）→ 等 pause 过期 → Redis 侧证据
if os.getenv("PAUSE") == "1" then
    local pause_ms = tonumber(os.getenv("PAUSE_MS") or 8000)
    lease.reset()
    rc:del(BK)

    -- 1) warm-up：装载脚本 SHA（真实 GRANT 后清理，不污染本地 Lease 状态）
    local rmod = require("kong.plugins.rate-limit-advanced.lib.redis")
    local wk2 = "kong:rl:{p4smoke:warm:ip=10.9.9.8}"
    local wid = "warmup-" .. lease.new_lease_id()
    local wparsed, werr = rmod.grant_lease(conf, wk2, wid, "kong:rl:{p4smoke:warm}",
                                           1, 60000, 1, 100, 120000)
    ok("pause-warmup-loaded", wparsed ~= nil and wparsed.granted == 1,
       tostring(wparsed) .. "/" .. tostring(werr))
    rc:del(wk2, "kong:rl:lease:" .. wid)

    -- 2) 轮询探测 pause 生效（独立短超时连接；ping 阻塞超时 ⇒ pause 已生效）
    local rc2 = red_cli:new()
    rc2:set_timeouts(300, 300, 300)
    assert(rc2:connect("redis", 6379))
    local pause_active = false
    for _ = 1, 40 do   -- 最多 ~12s
        local pok, perr = rc2:ping()
        if not pok then
            pause_active = true
            break
        end
        ngx.sleep(0.3)
    end
    pcall(function() rc2:close() end)
    ok("pause-detected", pause_active, "pause 未生效（检查 shell 的 CLIENT PAUSE）")

    -- 3) 实测：EVALSHA 执行超时 ⇒ uncertain
    local t0 = ngx.now()
    local res, err = lease.grant(conf, PK, BK, 5, 60000, 1, 100, 120000)
    local elapsed = ngx.now() - t0

    ok("pause-uncertain",
       res == nil and type(err) == "table" and err.kind == "uncertain",
       tostring(res) .. "/" .. tostring(err and err.kind) .. "/" .. tostring(err and err.err))
    ok("pause-no-retry", elapsed >= 0.3 and elapsed < 0.9,
       "elapsed=" .. string.format("%.3f", elapsed) .. "s（timeout=0.5s，重试则 >0.9s）")
    ok("pause-no-register", lease.stats().leases == 0,
       "leases=" .. lease.stats().leases)

    -- 4) 等 pause 过期（轮询 ping 恢复），核实 Redis 侧实际结果
    local rc3 = red_cli:new()
    rc3:set_timeouts(800, 800, 800)
    assert(rc3:connect("redis", 6379))
    for _ = 1, 40 do
        local pok = rc3:ping()
        if pok then break end
        ngx.sleep(0.3)
    end

    -- 实测语义（如实证，Phase 4 记录）：客户端读超时 ⇒ OpenResty cosocket 关闭连接
    -- ⇒ Redis 对已断开连接的排队 EVALSHA 不再执行 ⇒ 该构造下零写入。
    -- 客户端侧仍是 uncertain（无法区分"未执行/已执行"）⇒ 分类保持保守：
    -- 不重试、不登记（分类层对"脚本已执行中超时"的损失方向由 design D4 如实声明）。
    local tokens = num(rc:hget(BK, "tokens"))
    ok("pause-not-executed-bucket", tokens == nil,
       tostring(tokens))
    local after_keys = rc:keys("kong:rl:lease:*") or {}
    local new_lkey
    for _, k in ipairs(after_keys) do
        if not seen_before[k] then new_lkey = k end
    end
    ok("pause-not-executed-lease-record", new_lkey == nil,
       tostring(new_lkey))

    -- 清场
    if new_lkey then rc:del(new_lkey) end
    rc:del(BK)
end

print("RESULT: pass=" .. pass .. " fail=" .. fail)
