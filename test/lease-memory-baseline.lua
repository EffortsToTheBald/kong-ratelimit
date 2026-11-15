-- ============================================================
-- lease-memory-baseline.lua —— Gate 1 memory probe (read-only against production code, no production code changes)
--
-- Measurement notes (must-read for interpreting results):
--   collectgarbage("count") returns KBs of the LuaJIT GC heap — it only counts Lua objects
--   (tables/strings/numbers etc. allocated by the Lua VM). It does not include:
--     * nginx / OpenResty's own memory
--     * process RSS (counted by the OS, including C-level allocations)
--     * other Workers
--   Therefore this probe can only prove "Lease object lifetime and GC reclamation are correct,
--   plus Lua heap cost". It cannot substitute for RSS observation on real Kong Workers
--   (the latter is marked NOT RUN, see REMEDIATION.md).
--
-- Scenario: 100k distinct pool_keys, each registering 1 Lease (granted=10) and consuming 3 locally.
-- Output: heap before GC after allocation, heap after GC, net increase, and derived per-Pool / per-Lease bytes.
-- Run: docker compose cp into kong1, then resty execution (same pattern as lease-unit.sh).
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
lease.MAX_POOLS = N   -- the probe directly creates N pools (the production path goes through ensure_capacity; the cap is raised directly in the test to match the scale)

-- create 100k independent pools, 1 Lease per pool with partial consumption (simulating a realistic mixed state)
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
print(string.format("delta_gc_kb=%.1f (vs baseline, after GC)", after_gc - base))
print(string.format("bytes_per_pool_derived=%.0f (delta_gc*1024/N, derived)", (after_gc - base) * 1024 / N))
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
print(string.format("after_reset_heap_kb=%.1f (evidence of object reclamation)", collectgarbage("count")))
