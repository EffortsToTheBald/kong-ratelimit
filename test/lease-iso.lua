-- lease-iso.lua —— 多 Worker 隔离验证（任务 4.5；双进程 = 双 Lua VM）
-- 用法：ISO_ID=<标识> resty /tmp/lease-iso.lua
-- 每个进程各自 require lease 模块（独立 VM 独立模块状态），
-- 在相同 pool_key 下登记自己的 Lease，然后输出本进程可见的状态。
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")
local iso = os.getenv("ISO_ID") or "anon"

-- 进程内单例：require 两次返回同一 table（= 同 Worker 内跨请求共享状态）
local again = require("kong.plugins.rate-limit-advanced.lib.lease")
if again ~= lease then
    print("SINGLETON-BROKEN")
    return
end

local PK = "kong:rl:{p4iso:ip=10.0.0.9}"   -- 双进程使用相同 pool_key

-- 登记本进程（= 本 Worker）的 Lease 并消费 1 个
local g = lease.register(PK, "lease-" .. iso, 3)
lease.take(PK)

-- 输出：本进程可见的 Lease 清单与 stats
local lines = {}
local pool = lease._pools[PK]
for i = 1, #pool.leases do
    lines[#lines + 1] = pool.leases[i].lease_id
end
local st = lease.stats()
print(string.format("VM=%s leases=%s active=%d granted=%d consumed=%d remaining=%d",
    iso, table.concat(lines, ","), st.active, st.granted, st.consumed, st.local_remaining))

-- 跨 Worker 消费证明：本进程 TAKE 只会取到自己的 lease_id
local _, _, lid = lease.take(PK)
print("TAKE=" .. tostring(lid) .. " expected=lease-" .. iso)
