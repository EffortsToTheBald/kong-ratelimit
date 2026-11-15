-- ============================================================
-- lease-concurrent-grant-probe.lua —— Gate 1 concurrent GRANT probe (read-only against production code)
--
-- Honesty statement (must-read for interpreting conclusions):
--   This probe simulates concurrency with Lua coroutines + a scheduler loop: coroutines only yield
--   (coroutine.yield) inside the transport layer injected via lease._transport, with yield-point
--   positions matching real cosocket read/write yield points; the TAKE/registration sections remain
--   non-yielding. But the scheduler is a plain Lua loop, not OpenResty's real cosocket/event
--   scheduling ⇒ this probe's results **must not be written up as real OpenResty concurrency
--   verification** (real-environment evidence: test/concurrent-lease-e2e.sh measured 270 concurrent
--   requests, marked as a comparison; this probe's conclusions are marked NOT VERIFIED pending real E2E review).
--
-- Quantification basis:
--   * in-flight GRANT (inflight) = GRANT calls that have entered transport but not yet received a response
--   * registered Lease count = the final length of that pool's pool.leases (= the number of confirmed_granted entries)
--   * confirmed_granted = sum of granted (granted tokens that succeeded and were registered)
--   * consumed = tokens_consumed; outstanding = local_remaining
--   * accounting identity check: confirmed_granted == consumed + outstanding (discarded=0)
--   * uncertain_lost: this probe's transport always succeeds, so it is always 0
-- Run: docker compose cp into kong1, then resty execution.
-- ============================================================
local algorithm = require("kong.plugins.rate-limit-advanced.lib.algorithm")
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")
local redis_mod = require("kong.plugins.rate-limit-advanced.lib.redis")

-- ---- kong global stub (same technique as algorithm-lease-unit.lua)----
kong = {
    log = { notice = function() end, err = function() end,
            warn = function() end, debug = function() end },
}

-- After Gate 3: concurrent requests take the batch=1 direct path (redis_mod.grant) while a single
-- in-flight GRANT is set ⇒ the probe must also count the direct-path stub, otherwise the direct path
-- would hit a real cosocket.
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
    batch = 10,          -- explicit batch, auto disabled
    namespace = "probe",
    redis = { key_prefix = "kong:rl" },
}

local PK = "kong:rl:{probe:ip=10.0.0.1}"

-- ---- transport injection: a fake "slow Redis" transport that yields ----
local inflight, max_inflight = 0, 0
local grant_calls = 0
local TICKS = tonumber(os.getenv("GRANT_TICKS") or 5)

local function slow_transport(conf, bucket_key, lease_id, pool_key,
                              batch, lease_ttl_ms, rate, capacity, bucket_ttl_ms)
    grant_calls = grant_calls + 1
    inflight = inflight + 1
    if inflight > max_inflight then max_inflight = inflight end
    for _ = 1, TICKS do
        coroutine.yield("grant_inflight")   -- simulate cosocket read/write yield points
    end
    inflight = inflight - 1
    -- isomorphic to a real GRANT_LEASE success return: granted=batch full grant
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

    -- scheduler loop: round-robin; when spawn_every>1, staggered starts at intervals (simulating an arrival rate)
    local live, step = n, 0
    local spawned = {}
    for i = 1, n do spawned[i] = false end
    while live > 0 do
        step = step + 1
        -- spawn spawn_every new coroutines per step (in the burst scenario spawn_every=n means starting all at once)
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
                    -- granted=0: this probe always succeeds, should never be reached
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
        "[%s] accounts: confirmed_granted(%d) = consumed(%d) + outstanding(%d) + discarded(0); %d direct-path grants stay out of the Lease ledger (existing batch=1 basis); uncertain_lost=0",
        label, confirmed, st.consumed, st.local_remaining, direct_calls))

    lease._transport = nil
    direct_calls = 0
end

-- Scenario 1: simultaneous arrival (burst) — all requests enter transport in the first scheduling batch
for _, n in ipairs({ 2, 10, 50, 100 }) do
    run("burst", n, n)
end

-- Scenario 2: staggered arrival — 1 new request per scheduling step (simulating arrival rate vs RTT race)
run("steady", 100, 1)

lease.reset()
print("NOTE: Lua coroutine interleaving model (yield points inside transport); real OpenResty cosocket concurrency verification NOT VERIFIED")
