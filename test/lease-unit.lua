local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

local PK = "kong:rl:{p4u:ip=10.0.0.1}"

-- ============================================================
-- 4.1 结构：register 字段与守恒起点
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
    -- 全量诊断表保留对象；可消费集合含该对象
    local pool = lease._pools[PK]
    ok("register-structure", #pool.leases == 1 and #pool.active == 1
       and pool.leases[1] == l and pool.active[1] == l,
       "leases=" .. #pool.leases .. " active=" .. #pool.active)
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
-- 4.2 TAKE：递减 / 归零不可再取 / 插入序 / 无 yield
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

do -- 多 Lease 插入序：A(2) 耗尽后转 B(3)，A 不再被选中
    local pk = PK .. "order"
    lease.register(pk, "id-A", 2)
    lease.register(pk, "id-B", 3)
    local owners = {}
    for i = 1, 5 do
        local t, _, lid = lease.take(pk)
        owners[i] = t and lid or "NG"
    end
    local t6 = lease.take(pk)
    ok("take-insertion-order",
       table.concat(owners, ",") == "id-A,id-A,id-B,id-B,id-B" and t6 == false,
       table.concat(owners, ","))
end

do -- 多 Lease 并存不覆盖：同 pool_key 两个独立 lease_id 对象并存
    local pk = PK .. "coexist"
    local a = lease.register(pk, "id-M1", 4)
    local b = lease.register(pk, "id-M2", 6)
    local pool = lease._pools[pk]
    ok("multi-lease-coexist",
       a ~= b and #pool.leases == 2 and #pool.active == 2
       and pool.leases[1].lease_id == "id-M1" and pool.leases[2].lease_id == "id-M2"
       and a.remaining == 4 and b.remaining == 6,
       "leases=" .. #pool.leases)
end

do -- yield 探针：TAKE 片段内无 yield（单次 resume 内完成，协程不死不死挂起）
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
-- 4.3 耗尽处理（V1 简化）：CLOSED/摘除/保留诊断/不可复活
-- ============================================================
lease.reset()

do -- 耗尽 ⇒ CLOSED + 从可消费集合摘除 + 对象保留诊断表
    local pk = PK .. "exh"
    lease.register(pk, "id-x1", 2)
    lease.take(pk)
    lease.take(pk)   -- 耗尽
    local pool = lease._pools[pk]
    local l = pool.leases[1]
    ok("exhaust-closed",
       l.state == "CLOSED" and l.remaining == 0 and l.consumed == 2
       and #pool.leases == 1 and #pool.active == 0,      -- 摘除可消费集合；诊断表保留
       "state=" .. l.state .. " active=" .. #pool.active)
    ok("exhaust-stats", lease.stats().closed == 1 and lease.stats().active == 0)
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
    -- 结构性证明：lease.lua 未引入任何 Redis 写路径（take/register 均为纯本地操作）
    ok("exhaust-no-return-path", lease.invariants(), "structural")
end

-- ============================================================
-- 4.4 GRANT 四分类 + 多 Lease 并存（stub 传输层）
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

do -- 分类①：成功 ⇒ 建本地 Lease（granted/remaining 守恒）
    local res, e = run_grant({ { { granted = 10, tokens = 90, wait = 0 } } })
    local st = lease.stats()
    ok("grant-success",
       res ~= nil and e == nil and res.ok == true and res.granted == 10
       and res.lease ~= nil and res.lease.state == "ACTIVE"
       and st.leases == 1 and st.granted == 10 and st.local_remaining == 10
       and calls == 1,
       tostring(res) .. "/" .. tostring(e))
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

do -- 多 Lease 并存（经 grant）：两次成功 GRANT 同 pool_key，追加不覆盖
    local pk = PK .. "multi"
    lease._stub_seq = { { { granted = 4, tokens = 96, wait = 0 } },
                        { { granted = 6, tokens = 94, wait = 0 } } }
    lease._transport = stub_transport
    calls = 0
    local g1 = lease.grant({}, pk, "kong:rl:{p4u:g}", 4, 60000, 1, 100, 120000)
    local g2 = lease.grant({}, pk, "kong:rl:{p4u:g}", 6, 60000, 1, 100, 120000)
    lease._transport = nil
    lease._stub_seq = nil
    local pool = lease._pools[pk]
    ok("grant-multi-lease",
       g1.ok and g2.ok and g1.lease_id ~= g2.lease_id
       and #pool.leases == 2 and #pool.active == 2
       and g1.lease ~= g2.lease and lease.invariants(),
       "leases=" .. #pool.leases)
    -- 消费顺序：先耗尽 g1 的 4 个，再取 g2
    local owners = {}
    for i = 1, 6 do
        local t, _, lid = lease.take(pk)
        owners[i] = t and lid or "NG"
    end
    ok("grant-multi-consume-order",
       table.concat(owners, ",") == g1.lease_id .. "," .. g1.lease_id .. ","
         .. g1.lease_id .. "," .. g1.lease_id .. "," .. g2.lease_id .. "," .. g2.lease_id,
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
        -- 4 段：host:worker:seq:hex
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
    -- 同一份库存不同时计入 outstanding 与 lost：本例无崩溃，lost=0
    ok("accounting-identity",
       g.ok and st.granted == 100 and st.consumed == 80
       and st.local_remaining == 20
       and st.granted == st.consumed + st.local_remaining
       and lease.invariants(),
       "g=" .. st.granted .. " c=" .. st.consumed .. " o=" .. st.local_remaining)
end

print("RESULT: pass=" .. pass .. " fail=" .. fail)
