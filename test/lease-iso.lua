-- lease-iso.lua —— multi-Worker isolation verification (task 4.5; two processes = two Lua VMs)
-- Usage: ISO_ID=<identifier> resty /tmp/lease-iso.lua
-- Each process requires the lease module on its own (independent VM, independent module state),
-- registers its own Lease under the same pool_key, then prints the state visible to this process.
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")
local iso = os.getenv("ISO_ID") or "anon"

-- In-process singleton: requiring twice returns the same table (= shared state across requests within one Worker)
local again = require("kong.plugins.rate-limit-advanced.lib.lease")
if again ~= lease then
    print("SINGLETON-BROKEN")
    return
end

local PK = "kong:rl:{p4iso:ip=10.0.0.9}"   -- both processes use the same pool_key

-- Register this process's (= this Worker's) Lease and consume 1 token
local g = lease.register(PK, "lease-" .. iso, 3)
lease.take(PK)

-- Output: the Lease list and stats visible to this process
-- (Gate 3: terminal-state objects are released immediately, diagnostic listing removed
-- ⇒ take lease_id from the active set)
local lines = {}
local pool = lease._pools[PK]
for i = 1, #pool.active do
    lines[#lines + 1] = pool.active[i].lease_id
end
local st = lease.stats()
print(string.format("VM=%s leases=%s active=%d granted=%d consumed=%d remaining=%d",
    iso, table.concat(lines, ","), st.active, st.granted, st.consumed, st.local_remaining))

-- Cross-Worker consumption proof: this process's TAKE only takes its own lease_id
local _, _, lid = lease.take(PK)
print("TAKE=" .. tostring(lid) .. " expected=lease-" .. iso)
