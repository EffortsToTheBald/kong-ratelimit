-- ============================================================
-- lease-memory-baseline.lua —— 关口一内存探针（只读生产代码，不改生产代码）
--
-- 口径说明（结果解读必读）：
--   collectgarbage("count") 返回 LuaJIT GC 堆的 KB 数——只统计 Lua 对象
--   （table/string/number 等由 Lua VM 分配的部分）。它不包含：
--     * nginx / OpenResty 自身内存
--     * 进程 RSS（由 OS 统计，含 C 层分配）
--     * 其他 Worker
--   因此本探针只能证明"Lease 对象生命周期与 GC 回收正确、Lua 堆成本"，"
--   不能代替真实 Kong Worker 的 RSS 观察（后者标 NOT RUN，见 REMEDIATION.md）。
--
-- 场景：10 万个不同 pool_key，各登记 1 个 Lease（granted=10）并本地消费 3 个。
-- 输出：分配后 GC 前堆、GC 后堆、净增、折算每 Pool / 每 Lease 字节（推导）。
-- 运行：docker compose cp 进 kong1 后 resty 执行（与 lease-unit.sh 同模式）。
-- ============================================================
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

local N = tonumber(os.getenv("N_POOLS") or 100000)
local GRANTED = 10
local CONSUME = 3

local function gc()
    collectgarbage("collect")
    collectgarbage("collect")
    return collectgarbage("count")
end

print(string.format("jit=%s  N_POOLS=%d granted=%d consume=%d",
    jit and jit.version or _VERSION, N, GRANTED, CONSUME))

local base = gc()
print(string.format("baseline_heap_kb=%.1f", base))

lease.reset()

-- 建 10 万个独立 pool，每 pool 1 个 Lease 并消耗一部分（模拟真实混合状态）
for i = 1, N do
    local pk = string.format("kong:rl:{probe:ip=10.%d.%d.%d}",
        math.floor(i / 65536) % 256, math.floor(i / 256) % 256, i % 256)
    local l = lease.register(pk, "lease-" .. i, GRANTED)
    if not l then
        print("FAIL register " .. i)
        return
    end
    for _ = 1, CONSUME do
        local ok, rem = lease.take(pk)
        if not ok then
            print("FAIL take " .. i)
            return
        end
    end
end

local after_alloc = collectgarbage("count")
collectgarbage("collect")
local after_gc = collectgarbage("count")

local st = lease.stats()
local inv, inv_err = lease.invariants()

print(string.format("after_alloc_heap_kb=%.1f", after_alloc))
print(string.format("after_gc_heap_kb=%.1f", after_gc))
print(string.format("delta_alloc_kb=%.1f (vs baseline)", after_alloc - base))
print(string.format("delta_gc_kb=%.1f (vs baseline, GC 后)", after_gc - base))
print(string.format("bytes_per_pool_derived=%.0f (delta_gc*1024/N, 推导)", (after_gc - base) * 1024 / N))
print(string.format(
    "stats: leases=%d granted=%d consumed=%d closed=%d active=%d local_remaining=%d",
    st.leases, st.granted, st.consumed, st.closed, st.active, st.local_remaining))
print(string.format("expected: leases=%d granted=%d consumed=%d active=%d local_remaining=%d",
    N, N * GRANTED, N * CONSUME, N, N * (GRANTED - CONSUME)))

if inv then
    print("invariants=true")
    print("RESULT: pass=1 fail=0")
else
    print("invariants=false reason=" .. tostring(inv_err))
    print("RESULT: pass=0 fail=1")
end

lease.reset()
collectgarbage("collect")
print(string.format("after_reset_heap_kb=%.1f (对象可回收性证据)", collectgarbage("count")))
