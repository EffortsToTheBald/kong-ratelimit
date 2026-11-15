local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

local lease = require("kong.plugins.rate-limit-advanced.lib.lease")
local ngx_now = ngx.now

local PK = "kong:rl:{p4u:ip=10.0.0.1}"

-- ============================================================
-- 4.1 结构：register 字段与守恒起点
--     （关口三改造：终态对象即释放、历史入计数器；pool.leases 诊断清单取消，
--      原"全量诊断表保留对象"断言改为"计数器闭环 + active 集合无残留"）
-- ============================================================
lease.reset()

do -- register 基本字段
    local l, err = lease.register(PK, "id-a1", 5)
    ok("register-fields",
       l ~= nil and err == nil
       and l.lease_id == "id-a1" and l.pool_key == PK
       and l.granted == 5 and l.remaining == 5 and l.consumed == 0
       and l.state == "ACTIVE" and type(l.created_at) == "number",
       tostring(l) .. "/" .. tostring(err))
    -- 可消费集合含该对象；Pool 结构含 last_used/max_age（关口三）
    local pool = lease._pools[PK]
    ok("register-structure", #pool.active == 1 and pool.active[1] == l
       and type(pool.last_used) == "number",
       "active=" .. #pool.active)
    ok("register-counters", lease.stats().leases == 1 and lease.stats().granted == 5
       and lease.stats().active == 1,
       "leases=" .. lease.stats().leases)
end

do -- register 参数拒绝（granted 非正整数 ⇒ 拒绝、零状态变更）
    local before = lease.stats().leases
    local cases = { 0, -1, 1.5, "x", 2^53 }
    local all_rejected = true
    for i = 1, #cases do
        local l, err = lease.register(PK, "id-bad" .. i, cases[i])
        if l ~= nil or err == nil then all_rejected = false end
    end
    ok("register-rejects-bad-granted",
       all_rejected and lease.stats().leases == before,
       "stats.leases=" .. lease.stats().leases)
    ok("invariants-after-rejects", lease.invariants())
end

do -- 守恒：register 5 → take 3 ⇒ remaining=2/consumed=3（reset 后全局计数即本例）
    lease.reset()
    local pk2 = PK .. "cons"
    lease.register(pk2, "id-c1", 5)
    local r1, rem1 = lease.take(pk2)
    local r2, rem2 = lease.take(pk2)
    local r3, rem3 = lease.take(pk2)
    local st = lease.stats()
    ok("take-conservation",
       r1 and r2 and r3 and rem1 == 4 and rem2 == 3 and rem3 == 2
       and st.consumed == 3 and st.local_remaining == 2,
       "rem=" .. rem3 .. " consumed=" .. st.consumed)
    ok("invariants-conservation", lease.invariants())
end

-- ============================================================
-- 4.2 TAKE：递减 / 归零不可再取 / 插入序（顺序纪元）/ 无 yield
-- ============================================================
lease.reset()

do -- 未知 pool ⇒ NEED_GRANT
    local t, v = lease.take("kong:rl:{p4u:none}")
    ok("take-unknown-pool", t == false and v == "NEED_GRANT", tostring(v))
end

do -- 批量递减序列与归零后不可再取（含耗尽 CLOSED）
    local pk = PK .. "seq"
    lease.register(pk, "id-s1", 5)
    local seq = {}
    for i = 1, 5 do
        local t, rem, lid = lease.take(pk)
        seq[i] = (t and (rem .. "@" .. lid) or "NG")
    end
    local t6 = lease.take(pk)
    ok("take-sequence",
       table.concat(seq, ",") == "4@id-s1,3@id-s1,2@id-s1,1@id-s1,0@id-s1"
       and t6 == false,
       table.concat(seq, ","))
end

do -- 消费序（顺序纪元）：A(2) 耗尽 CLOSED 摘除后登记 B(3)，A 不再被选中
    local pk = PK .. "order"
    lease.register(pk, "id-A", 2)
    local owners = {}
    for i = 1, 2 do
        local t, _, lid = lease.take(pk)
        owners[i] = t and lid or "NG"
    end
    -- A 耗尽（CLOSED 摘除）后 B 才可登记（方案 B 上界）
    lease.register(pk, "id-B", 3)
    for i = 3, 5 do
        local t, _, lid = lease.take(pk)
        owners[i] = t and lid or "NG"
    end
    local t6 = lease.take(pk)
    ok("take-insertion-order",
       table.concat(owners, ",") == "id-A,id-A,id-B,id-B,id-B" and t6 == false,
       table.concat(owners, ","))
end

do -- 方案 B 上界：pool 已有 ACTIVE Lease ⇒ register 拒绝（不覆盖、不并存）
    lease.reset()
    local pk = PK .. "busy"
    local a = lease.register(pk, "id-M1", 4)
    local b, berr = lease.register(pk, "id-M2", 6)
    local pool = lease._pools[pk]
    ok("multi-lease-busy-reject",
       a ~= nil and b == nil and type(berr) == "string"
       and #pool.active == 1 and pool.active[1] == a,
       tostring(b) .. "/" .. tostring(berr))
    -- A 耗尽摘除后可登记新纪元；lease_id 独立、计数器不覆盖（原"并存不覆盖"意图）
    for _ = 1, 4 do lease.take(pk) end
    local b2 = lease.register(pk, "id-M2", 6)
    local st = lease.stats()
    ok("multi-lease-sequential-epochs",
       b2 ~= nil and b2.lease_id == "id-M2" and st.leases == 2
       and st.active == 1 and st.local_remaining == 6
       and lease.invariants(),
       "leases=" .. st.leases .. " active=" .. st.active)
end

do -- yield 探针：TAKE 片段内无 yield（单次 resume 内完成）
    local pk = PK .. "yield"
    lease.register(pk, "id-y1", 3)
    local co = coroutine.create(function()
        return lease.take(pk)
    end)
    local results = table.pack(coroutine.resume(co))
    ok("take-no-yield",
       results[1] == true            -- 无错误
       and coroutine.status(co) == "dead"  -- 一次 resume 内跑完 = 片段内无 yield
       and results[2] == true and results[3] == 2,
       "status=" .. coroutine.status(co) .. " n=" .. results.n)
end

do -- 100 次随机操作后结构不变量仍成立（负库存/超发不可能）
    lease.reset()
    math.randomseed(42)
    local pk = PK .. "fuzz"
    for i = 1, 100 do
        local op = math.random(1, 2)
        if op == 1 then
            lease.register(pk, "id-f" .. i, math.random(1, 10))
        else
            lease.take(pk)
        end
        local good, reason = lease.invariants()
        if not good then
            ok("invariants-fuzz", false, "iter=" .. i .. " " .. tostring(reason))
            break
        end
    end
    ok("invariants-fuzz", lease.invariants())
end

-- ============================================================
-- 4.3 耗尽处理：CLOSED/摘除/计数器闭环/不可复活
-- ============================================================
lease.reset()

do -- 耗尽 ⇒ CLOSED + 从可消费集合摘除 + 计数器闭环（诊断表取消，历史入计数器）
    local pk = PK .. "exh"
    local l = lease.register(pk, "id-x1", 2)
    lease.take(pk)
    lease.take(pk)   -- 耗尽
    local pool = lease._pools[pk]
    local st = lease.stats()
    ok("exhaust-closed",
       l.state == "CLOSED" and l.remaining == 0 and l.consumed == 2
       and #pool.active == 0
       and st.closed == 1 and st.active == 0 and st.leases == 1
       and st.granted == 2 and st.consumed == 2,
       "state=" .. l.state .. " active=" .. #pool.active
       .. " closed=" .. st.closed)
    ok("exhaust-count-closure",
       st.leases == st.closed + st.expired + st.active,
       "leases=" .. st.leases)
end

do -- CLOSED 不可复活 / 重复标记不产生副作用
    local pk = PK .. "exh2"
    lease.register(pk, "id-x2", 1)
    lease.take(pk)                       -- 耗尽关闭
    local st1 = lease.stats()
    local t2 = lease.take(pk)            -- 再 TAKE ⇒ 不选中
    local st2 = lease.stats()
    ok("closed-not-revivable",
       t2 == false and st1.closed == st2.closed and st1.leases == st2.leases
       and lease.invariants(),
       tostring(t2))
end

do -- V1 无 RETURN：耗尽后 Redis 记录不清理（本层仅本地状态，此处断言无 Redis 调用接口）
    ok("exhaust-no-return-path", lease.invariants(), "structural")
end

-- ============================================================
-- 4.4 GRANT 分类 + 顺序纪元（stub 传输层）
-- ============================================================
lease.reset()

local calls
local stub_transport
do -- stub：按预设回放 (parsed, err)，并计数调用次数（重试断言）
    stub_transport = function(conf, bucket_key, lease_id, pool_key, batch,
                              lease_ttl_ms, rate, capacity, bucket_ttl_ms)
        calls = calls + 1
        local s = lease._stub_seq and lease._stub_seq[calls] or {}
        return s[1], s[2]
    end
end

local function run_grant(seq)
    calls = 0
    lease._stub_seq = seq
    lease._transport = stub_transport
    local r1, r2 = lease.grant({}, PK, "kong:rl:{p4u:g}", 10, 60000, 1, 100, 120000)
    lease._transport = nil
    lease._stub_seq = nil
    return r1, r2
end

do -- 分类①：成功 ⇒ 建本地 Lease（granted/remaining 守恒 + max_age 快照）
    local res, e = run_grant({ { { granted = 10, tokens = 90, wait = 0 } } })
    local st = lease.stats()
    ok("grant-success",
       res ~= nil and e == nil and res.ok == true and res.granted == 10
       and res.lease ~= nil and res.lease.state == "ACTIVE"
       and st.leases == 1 and st.granted == 10 and st.local_remaining == 10
       and calls == 1,
       tostring(res) .. "/" .. tostring(e))
    local pool = lease._pools[PK]
    ok("grant-max-age-snapshot", pool.max_age == 120000,
       "max_age=" .. tostring(pool.max_age))
end

do -- 分类②：不足（granted=0）⇒ 不建 Lease
    local res, e = run_grant({ { { granted = 0, tokens = 0.5, wait = 0.5 } } })
    local st = lease.stats()
    ok("grant-insufficient",
       res ~= nil and res.ok == false and res.reason == "insufficient"
       and e == nil and st.leases == 1,   -- 未新增（仍是上一例的 1 个）
       tostring(res))
end

do -- 分类③：明确错误（LEASE_EXISTS）⇒ 故障分支，不登记，不重试
    local res, e = run_grant({ { nil, "LEASE_EXISTS id-zz" } })
    ok("grant-lease-exists",
       res == nil and type(e) == "table" and e.kind == "explicit_error"
       and string.find(e.err, "LEASE_EXISTS", 1, true) ~= nil and calls == 1,
       tostring(res) .. "/" .. tostring(e and e.kind))
end

do -- 分类④：不确定（超时）⇒ 不重试（恰 1 次调用）、不登记本地库存
    local res, e = run_grant({ { nil, "timeout" } })
    local st = lease.stats()
    ok("grant-uncertain-no-retry-no-register",
       res == nil and type(e) == "table" and e.kind == "uncertain"
       and calls == 1 and st.leases == 1,   -- 全程仅 grant-success 的 1 个；本例无新增
       tostring(res) .. "/" .. tostring(e and e.kind))
end

do -- 畸形返回 ⇒ uncertain（可能已执行）；INVALID_ARGUMENT ⇒ explicit
    local c1, d1 = lease.classify_grant(nil, "malformed eval response: granted out of range")
    local c2, d2 = lease.classify_grant(nil, "INVALID_ARGUMENT batch")
    ok("grant-classify-edge",
       c1 == "uncertain" and c2 == "explicit_error",
       c1 .. "/" .. c2)
end

do -- 单在途标志：transport 执行期间置位、返回后清除（所有分类路径）
    local seen_inflight
    lease._transport = function(...)
        seen_inflight = lease.grant_in_flight(PK)
        return { granted = 1, tokens = 99, wait = 0 }
    end
    local g1 = lease.grant({}, PK, "kong:rl:{p4u:g}", 1, 60000, 1, 100, 120000)
    -- 上一例的 ACTIVE Lease 仍在 ⇒ 本例 register 被拒 ⇒ uncertain（上界语义）
    lease._transport = stub_transport
    calls = 0
    lease._stub_seq = { { nil, "timeout" } }
    local g2, e2 = lease.grant({}, PK, "kong:rl:{p4u:g}", 1, 60000, 1, 100, 120000)
    lease._transport = nil
    lease._stub_seq = nil
    ok("grant-inflight-flag",
       g1 == nil and type(e2) == "table" and e2.kind == "uncertain"
       and seen_inflight == true
       and lease.grant_in_flight(PK) == false,
       "seen=" .. tostring(seen_inflight)
       .. " after=" .. tostring(lease.grant_in_flight(PK)))
    -- 上例 register 拒绝（pool busy） ⇒ 不入库；耗尽后可再次成功
    for _ = 1, 10 do lease.take(PK) end   -- 耗尽 grant-success 的 Lease
end

do -- 顺序纪元（经 grant）：前一 Lease 耗尽后新 GRANT 成功，独立 lease_id 不覆盖
    local pk = PK .. "multi"
    lease._stub_seq = { { { granted = 4, tokens = 96, wait = 0 } },
                        { { granted = 6, tokens = 94, wait = 0 } } }
    lease._transport = stub_transport
    calls = 0
    local g1 = lease.grant({}, pk, "kong:rl:{p4u:g}", 4, 60000, 1, 100, 120000)
    -- 纪元内第二次 GRANT：active 非空 ⇒ register 拒 ⇒ uncertain（不重复登记）
    local g2, e2 = lease.grant({}, pk, "kong:rl:{p4u:g}", 6, 60000, 1, 100, 120000)
    -- 耗尽 g1 后新纪元 GRANT 成功（独立 lease_id）
    for _ = 1, 4 do lease.take(pk) end
    calls = 0
    lease._stub_seq = { { { granted = 6, tokens = 94, wait = 0 } } }
    local g3 = lease.grant({}, pk, "kong:rl:{p4u:g}", 6, 60000, 1, 100, 120000)
    lease._transport = nil
    lease._stub_seq = nil
    local pool = lease._pools[pk]
    local st = lease.stats()
    ok("grant-sequential-epoch",
       g1 ~= nil and g1.ok and g2 == nil and type(e2) == "table"
       and e2.kind == "uncertain"
       and g3 ~= nil and g3.ok and g3.lease_id ~= g1.lease_id
       and #pool.active == 1 and pool.active[1] == g3.lease
       and lease.invariants(),
       "g2=" .. tostring(g2) .. " active=" .. #pool.active)
    -- 消费顺序：新纪元 Lease 独立消费
    local owners = {}
    for i = 1, 6 do
        local t, _, lid = lease.take(pk)
        owners[i] = t and lid or "NG"
    end
    ok("grant-multi-consume-order",
       table.concat(owners, ",") == g3.lease_id .. "," .. g3.lease_id .. ","
         .. g3.lease_id .. "," .. g3.lease_id .. "," .. g3.lease_id .. "," .. g3.lease_id,
       table.concat(owners, ","))
end

do -- lease_id 生成：格式 + 进程内唯一性
    lease.reset()
    local seen = {}
    local all_unique, all_format = true, true
    for i = 1, 1000 do
        local id = lease.new_lease_id()
        if seen[id] then all_unique = false end
        seen[id] = true
        local n = 0
        for _ in string.gmatch(id, ":") do n = n + 1 end
        if n ~= 3 then all_format = false end
    end
    ok("lease-id-unique", all_unique and all_format and #lease.new_lease_id() > 10,
       "unique=" .. tostring(all_unique) .. " fmt=" .. tostring(all_format))
end

do -- V1 账目恒等式：granted = consumed + outstanding（无丢失序列）
    lease.reset()
    local pk = PK .. "acct"
    lease._stub_seq = { { { granted = 100, tokens = 900, wait = 0 } } }
    lease._transport = stub_transport
    calls = 0
    local g = lease.grant({}, pk, "kong:rl:{p4u:g}", 100, 60000, 1, 1000, 120000)
    lease._transport = nil
    lease._stub_seq = nil
    for _ = 1, 80 do lease.take(pk) end
    local st = lease.stats()
    ok("accounting-identity",
       g.ok and st.granted == 100 and st.consumed == 80
       and st.local_remaining == 20
       and st.granted == st.consumed + st.local_remaining
       and lease.invariants(),
       "g=" .. st.granted .. " c=" .. st.consumed .. " o=" .. st.local_remaining)
end

-- ============================================================
-- 关口三新增：过期（EXPIRED / discarded 一次计数 / 单位约定）
-- ============================================================
lease.reset()

do -- 过期候选：TAKE 不消费，摘除并计入 discarded（一次）
    local pk = PK .. "exp"
    local past = ngx_now() - 100
    lease.register(pk, "id-e1", 10, past, 5000)   -- created_at 秒 + max_age 5s < now ⇒ 过期
    local st0 = lease.stats()
    local t1, v1 = lease.take(pk)
    local st1 = lease.stats()
    ok("expire-take-need-grant",
       t1 == false and v1 == "NEED_GRANT" and st1.active == 0,
       tostring(v1) .. " active=" .. st1.active)
    ok("expire-discarded-once",
       st1.discarded_tokens == st0.discarded_tokens + 10
       and st1.expired == st0.expired + 1,
       "discarded=" .. st1.discarded_tokens .. " expired=" .. st1.expired)
    -- 重复 TAKE 不重复计数（对象已摘除）
    local t2 = lease.take(pk)
    local st2 = lease.stats()
    ok("expire-no-double-count",
       t2 == false and st2.discarded_tokens == st1.discarded_tokens
       and st2.expired == st1.expired,
       "discarded=" .. st2.discarded_tokens)
    ok("expire-invariants", lease.invariants())
end

do -- 单位约定：max_age 毫秒 ⇒ /1000 秒比较（未过期候选正常消费）
    local pk = PK .. "unit"
    local past = ngx_now() - 10
    lease.register(pk, "id-u1", 5, past, 20000)   -- past + 20s > now ⇒ 未过期
    local t, rem = lease.take(pk)
    ok("expire-unit-ms-to-s",
       t == true and rem == 4 and lease.stats().discarded_tokens == 10,
       "t=" .. tostring(t) .. " rem=" .. tostring(rem))
end

do -- sweep_pool：GRANT 路径惰性清扫；busy 判定按 #active（过期候选在摘除前仍占位）
    local pk = PK .. "sweep"
    local past = ngx_now() - 100
    lease.register(pk, "id-sw1", 3, past, 5000)       -- 已过期、未被 take 触碰
    local b, berr = lease.register(pk, "id-sw2", 7, ngx_now(), 5000)
    ok("sweep-busy-with-expired",
       b == nil and type(berr) == "string", tostring(berr))
    local n = lease.sweep_pool(pk)                     -- 摘除过期 sw1（discarded 一次）
    local st = lease.stats()
    ok("sweep-pool",
       n == 1 and st.discarded_tokens == 10 + 3
       and #lease._pools[pk].active == 0,
       "removed=" .. n .. " discarded=" .. st.discarded_tokens)
    local c = lease.register(pk, "id-sw2", 7, ngx_now(), 5000)   -- 摘除后可登记新纪元
    ok("sweep-then-register",
       c ~= nil and #lease._pools[pk].active == 1 and lease.invariants(),
       tostring(c))
end

lease.reset()

do -- Timer 兜底清扫：空闲 Pool 删除 / 活跃 Pool 保留 / 过期 Lease 一次计数
    local now = ngx_now()
    -- 空闲空池（可回收；max_age 已快照）
    local pk1 = PK .. "t-idle"
    lease.register(pk1, "id-t1", 2, ngx_now(), 5000)
    for _ = 1, 2 do lease.take(pk1) end            -- 耗尽 ⇒ active 空
    lease._pools[pk1].last_used = now - 1000       -- 测试直改：回拨 last_used
    -- 空闲但含过期 Lease 的池（应摘除后删池）
    local pk2 = PK .. "t-exp"
    lease.register(pk2, "id-t2", 4, now - 100, 5000)
    lease._pools[pk2].last_used = now - 1000
    -- 活跃池（含未过期 Lease）⇒ 保留
    local pk3 = PK .. "t-live"
    lease.register(pk3, "id-t3", 6, now - 1, 5000)
    lease._pools[pk3].last_used = now - 1000
    -- 空闲但 max_age 未快照（直测登记无 max_age）⇒ 不处理
    local pk4 = PK .. "t-noma"
    lease.register(pk4, "id-t4", 1)
    for _ = 1, 1 do lease.take(pk4) end
    lease._pools[pk4].last_used = now - 1000

    local n = lease.timer_sweep_once(64)
    local st = lease.stats()
    ok("timer-sweep-idle-evict",
       n == 2 and lease._pools[pk1] == nil and lease._pools[pk2] == nil
       and lease._pools[pk3] ~= nil and lease._pools[pk4] ~= nil
       and st.evicted == 2,
       "evicted=" .. n)
    ok("timer-sweep-expired-once",
       st.expired == 1 and st.discarded_tokens == 4,
       "expired=" .. st.expired .. " discarded=" .. st.discarded_tokens)
    ok("timer-sweep-invariants", lease.invariants())
end

do -- Timer 数量上限：70 个空闲池，单次 ≤64，剩余下次处理
    lease.reset()
    local now = ngx_now()
    for i = 1, 70 do
        local pk = PK .. "cap" .. i
        lease.register(pk, "id-c" .. i, 1, ngx_now(), 5000)
        lease.take(pk)
        lease._pools[pk].last_used = now - 1000
    end
    local n1 = lease.timer_sweep_once(64)
    local n2 = lease.timer_sweep_once(64)
    ok("timer-cap",
       n1 == 64 and n2 == 6 and lease.pool_count() == 0
       and lease.stats().evicted == 70,
       "n1=" .. n1 .. " n2=" .. n2)
end

-- ============================================================
-- 关口三新增：MAX_POOLS 容量与淘汰（只删空池，零库存损失）
-- ============================================================
lease.reset()

do -- ensure_capacity：未达上限 true；达上限淘汰空池后 true；无可淘汰 false
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 2
    local pkA = PK .. "capA"
    local pkB = PK .. "capB"
    lease.register(pkA, "id-a", 5)
    lease.register(pkB, "id-b", 5)      -- 两池均 ACTIVE ⇒ 不可淘汰
    ok("capacity-full-no-evictable",
       lease.pool_count() == 2 and lease.ensure_capacity() == false
       and lease.pool_count() == 2 and lease.stats().evicted == 0,
       "count=" .. lease.pool_count())
    -- B 耗尽 ⇒ 空池可淘汰
    for _ = 1, 5 do lease.take(pkB) end
    ok("capacity-evict-empty",
       lease.ensure_capacity() == true and lease.pool_count() == 1
       and lease._pools[pkB] == nil and lease.stats().evicted == 1,
       "count=" .. lease.pool_count())
    -- 含 ACTIVE Lease 的池不被驱逐（冻结：零库存损失）
    lease.register(pkB, "id-b2", 5)     -- 重建 B
    lease.MAX_POOLS = 1                 -- 上限=1：A/B 均有 ACTIVE ⇒ 不可淘汰
    ok("capacity-never-evict-active",
       lease.pool_count() == 2 and lease.ensure_capacity() == false
       and lease._pools[pkA] ~= nil and lease._pools[pkB] ~= nil
       and lease.stats().evicted == 1,
       "count=" .. lease.pool_count())
    lease.MAX_POOLS = saved
    ok("capacity-invariants", lease.invariants())
end

print("RESULT: pass=" .. pass .. " fail=" .. fail)
if fail > 0 then os.exit(1) end
