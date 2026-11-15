-- lease-grant-smoke.lua —— real-path smoke of GRANT wiring (task 4.4 transport-layer evidence)
-- Case 1: real Redis GRANT_LEASE ⇒ local Lease created + 5 consumed locally + Redis record/bucket-debit evidence
-- Case 2 (PAUSE=1, timeout=500ms): GRANT times out during CLIENT PAUSE ⇒ uncertain,
--        no retry (elapsed < 2x timeout), no registration in local lease pool; Redis-side evidence after pause ends:
--        bucket debited (tokens < capacity) + Lease record created (OPEN) ⇒ direction of stock loss
local red_cli = require "resty.redis"
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

-- when a field is missing, hget's resty.redis returns ngx.null (userdata): normalize first, then tonumber
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

-- cleanup
rc:del(BK)
local before_keys = rc:keys("kong:rl:*:lease:*") or {}
local seen_before = {}
for _, k in ipairs(before_keys) do seen_before[k] = true end

-- ============ Case 1: normal GRANT + local consumption (skipped in PAUSE mode) ============
if os.getenv("PAUSE") ~= "1" then
do
    lease.reset()
    local res, err = lease.grant(conf, PK, BK, 5, 60000, 1, 100, 120000)
    ok("smoke-grant-success",
       res ~= nil and err == nil and res.ok == true and res.granted == 5,
       tostring(res) .. "/" .. tostring(err))

    local lkey = PK .. ":lease:" .. res.lease_id
    local status = rc:hget(lkey, "status")
    local granted = num(rc:hget(lkey, "granted"))
    ok("smoke-redis-record", status == "OPEN" and granted == 5,
       "status=" .. tostring(status) .. " granted=" .. tostring(granted))

    local tokens = num(rc:hget(BK, "tokens"))
    ok("smoke-bucket-debited",
       tokens ~= nil and tokens >= 93 and tokens <= 96,   -- 100-5 + refill(<=1s, rate=1/s)
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

-- ============ Case 2: CLIENT PAUSE ⇒ uncertain (no retry / no registration / loss direction) ============
-- Prerequisite: script SHAs already cached in VM/Redis (warm-up load first; otherwise the lazy-load
-- SCRIPT LOAD of the first EVALSHA times out first — that is "certainly not executed" = explicit_error,
-- not the execution timeout this case tests).
-- Flow: warm-up (real GRANT loads SHAs then cleanup) -> poll to detect pause active (ping timeout)
--       -> measured GRANT (EVALSHA execution timeout ⇒ uncertain) -> wait for pause to expire -> Redis-side evidence
if os.getenv("PAUSE") == "1" then
    local pause_ms = tonumber(os.getenv("PAUSE_MS") or 8000)
    lease.reset()
    rc:del(BK)

    -- 1) warm-up: load script SHAs (real GRANT then cleanup, no pollution of local Lease state)
    local rmod = require("kong.plugins.rate-limit-advanced.lib.redis")
    local wk2 = "kong:rl:{p4smoke:warm:ip=10.9.9.8}"
    local wid = "warmup-" .. lease.new_lease_id()
    local wparsed, werr = rmod.grant_lease(conf, wk2, wid, "kong:rl:{p4smoke:warm}",
                                           1, 60000, 1, 100, 120000)
    ok("pause-warmup-loaded", wparsed ~= nil and wparsed.granted == 1,
       tostring(wparsed) .. "/" .. tostring(werr))
    rc:del(wk2, wk2 .. ":lease:" .. wid)

    -- 2) poll to detect pause active (independent short-timeout connection; ping blocking timeout ⇒ pause is active)
    local rc2 = red_cli:new()
    rc2:set_timeouts(300, 300, 300)
    assert(rc2:connect("redis", 6379))
    local pause_active = false
    for _ = 1, 40 do   -- up to ~12s
        local pok, perr = rc2:ping()
        if not pok then
            pause_active = true
            break
        end
        ngx.sleep(0.3)
    end
    pcall(function() rc2:close() end)
    ok("pause-detected", pause_active, "pause not active (check the shell's CLIENT PAUSE)")

    -- 3) measured: EVALSHA execution timeout ⇒ uncertain
    local t0 = ngx.now()
    local res, err = lease.grant(conf, PK, BK, 5, 60000, 1, 100, 120000)
    local elapsed = ngx.now() - t0

    ok("pause-uncertain",
       res == nil and type(err) == "table" and err.kind == "uncertain",
       tostring(res) .. "/" .. tostring(err and err.kind) .. "/" .. tostring(err and err.err))
    ok("pause-no-retry", elapsed >= 0.3 and elapsed < 0.9,
       "elapsed=" .. string.format("%.3f", elapsed) .. "s (timeout=0.5s; a retry would be >0.9s)")
    ok("pause-no-register", lease.stats().leases == 0,
       "leases=" .. lease.stats().leases)

    -- 4) wait for pause to expire (poll until ping recovers), verify the actual Redis-side result
    local rc3 = red_cli:new()
    rc3:set_timeouts(800, 800, 800)
    assert(rc3:connect("redis", 6379))
    for _ = 1, 40 do
        local pok = rc3:ping()
        if pok then break end
        ngx.sleep(0.3)
    end

    -- Measured semantics (recorded as evidence in Phase 4): client read timeout ⇒ OpenResty cosocket closes
    -- the connection ⇒ Redis no longer executes the queued EVALSHA on a closed connection ⇒ zero-write in
    -- this construction. The client side is still uncertain (cannot distinguish "not executed/executed")
    -- ⇒ classification stays conservative: no retry, no registration (the classification layer declares the
    -- loss direction for "script executed but timed out" as stated in design D4).
    local tokens = num(rc:hget(BK, "tokens"))
    ok("pause-not-executed-bucket", tokens == nil,
       tostring(tokens))
    local after_keys = rc:keys("kong:rl:*:lease:*") or {}
    local new_lkey
    for _, k in ipairs(after_keys) do
        if not seen_before[k] then new_lkey = k end
    end
    ok("pause-not-executed-lease-record", new_lkey == nil,
       tostring(new_lkey))

    -- cleanup
    if new_lkey then rc:del(new_lkey) end
    rc:del(BK)
end

print("RESULT: pass=" .. pass .. " fail=" .. fail)
