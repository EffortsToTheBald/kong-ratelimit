-- ============================================================
-- algorithm-lease-unit.lua —— 6.1 wiring unit tests: three-mode behavior matrix (resty)
--
-- Coverage (unit-test layer of user acceptance test §5 items 1/2/3/4/5/6/9/13):
--   A. batch=1 never touches Lease (redis grant called, transport zero calls, zero registration)
--   B. batch>1 first request triggers GRANT_LEASE: correct args, exactly 1 consumed after registration
--   C. subsequent requests take locally, no repeated Redis access
--   D. stock exhausted CLOSED removal + new Lease requested (multi-Lease coexistence without overwrite)
--   E. GRANT partial grant: register by actual granted, no double consumption
--   F. granted=0 ⇒ 429 (retry_after=wait passthrough, no registration)
--   G. explicit_error ⇒ fault branch (nil, err, no registration, no retry)
--   H. uncertain ⇒ fault branch (nil, err, no registration, no retry)
--   I. config change ⇒ pool_key fingerprint isolation (different keys do not share stock)
--   J. multi rules ⇒ GRANT_MULTI, no Lease touched
--
-- Reuses Phase 4 infrastructure: lease._transport injection + redis_mod monkeypatch (no new dependencies).
-- ============================================================
local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

local algorithm = require("kong.plugins.rate-limit-advanced.lib.algorithm")
local redis_mod = require("kong.plugins.rate-limit-advanced.lib.redis")
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

-- ---- kong global stub (build_key's ip dimension + logging) ----
kong = {
    log = { notice = function() end, err = function() end, warn = function() end, debug = function() end },
    client = { get_forwarded_ip = function() return "10.0.0.1" end,
               get_ip = function() return "10.0.0.1" end,
               get_consumer = function() return nil end },
    request = { get_path = function() return "/" end,
                get_method = function() return "GET" end,
                get_header = function() return nil end },
    router = { get_route = function() return nil end,
               get_service = function() return nil end },
}

-- ---- spies ----
local calls = { grant = 0, grant_multi = 0, transport = 0, warn = 0 }
local grant_ret       -- batch=1 stub return
local grant_multi_ret -- multi-rule stub return
local transport_ret   -- GRANT_LEASE stub returns {parsed} or nil, err
local transport_err   -- GRANT_LEASE stub second return value (err)

local orig_grant, orig_grant_multi = redis_mod.grant, redis_mod.grant_multi
redis_mod.grant = function(conf, key, batch, ttl_ms, rate, burst)
    calls.grant = calls.grant + 1
    return grant_ret
end
redis_mod.grant_multi = function(conf, keys, rates, bursts, ttls)
    calls.grant_multi = calls.grant_multi + 1
    return grant_multi_ret
end

local last_args
lease._transport = function(conf, bucket_key, lease_id, pool_key, batch,
                            lease_ttl_ms, rate, capacity, bucket_ttl_ms)
    calls.transport = calls.transport + 1
    last_args = { bucket_key = bucket_key, lease_id = lease_id,
                  pool_key = pool_key, batch = batch, ttl = lease_ttl_ms,
                  rate = rate, capacity = capacity, bucket_ttl = bucket_ttl_ms }
    return transport_ret, transport_err
end

-- kong stub extra: warn counter (pool_cap_degraded evidence)
local _warn = kong.log.warn
kong.log.warn = function(...) calls.warn = calls.warn + 1 end

local function base_conf()
    return {
        namespace = "rl", limit = 100, window = 3600, burst = nil,
        batch = 20, limit_by = { "ip" }, fault_tolerant = false,
        redis = { key_prefix = "kong:rl" },
    }
end

lease.reset()
grant_ret = { granted = 1, tokens = 99, wait = 0 }

-- ============================================================
-- A. batch=1: never touches Lease
-- ============================================================
do
    local conf = base_conf(); conf.batch = 1
    local key = algorithm.build_key(conf)
    local d = algorithm.check(conf, key)
    ok("A-batch1-uses-grant", d ~= nil and d.allowed == true
       and calls.grant == 1, tostring(d and d.allowed) .. "/" .. calls.grant)
    ok("A-batch1-zero-lease",
       calls.transport == 0 and lease.stats().leases == 0,
       "transport=" .. calls.transport .. " leases=" .. lease.stats().leases)
end

-- ============================================================
-- A2. consumer dimension anonymous fallback (Gate 6 guard test: unauthenticated ⇒ fixed "anon", anonymous shares the quota)
-- ============================================================
do
    local conf = base_conf()
    conf.batch = 1
    conf.limit_by = { "consumer" }
    local key = algorithm.build_key(conf)
    ok("A2-consumer-anon-fallback",
       type(key) == "string" and key:find(":consumer=anon}", 1, true) ~= nil,
       tostring(key))
end

-- ============================================================
-- B. batch>1 first request: GRANT_LEASE + exactly 1 consumed after registration
-- ============================================================
do
    lease.reset(); calls.grant, calls.transport = 0, 0
    transport_ret = { granted = 10, tokens = 90, wait = 0 }  -- granted=min(batch, floor(tokens))
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    local d = algorithm.check(conf, key)
    ok("B-first-grant-allowed", d ~= nil and d.allowed == true
       and d.remaining == 9, tostring(d and d.remaining))
    ok("B-transport-args", calls.transport == 1
       and last_args.pool_key == key and last_args.bucket_key == key
       and last_args.batch == 20 and last_args.ttl == 3600000
       and math.abs(last_args.rate - 100/3600) < 1e-9
       and last_args.bucket_ttl == 3600 * 2 * 1000,
       "pool=" .. tostring(last_args.pool_key) .. " batch=" .. last_args.batch)
    local st = lease.stats()
    ok("B-register-consume-one", st.leases == 1 and st.local_remaining == 9
       and st.consumed == 1 and st.granted == 10,
       "leases=" .. st.leases .. " rem=" .. st.local_remaining)
    ok("B-no-repeat-redis", calls.grant == 0,
       "batch>1 must not take the batch=1 redis grant path: " .. calls.grant)
end

-- ============================================================
-- C. subsequent requests take locally, no repeated Redis access
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    calls.transport = 0
    local d = algorithm.check(conf, key)
    local st = lease.stats()
    ok("C-local-take", d ~= nil and d.allowed == true and d.remaining == 8
       and calls.transport == 0 and st.leases == 1,
       "rem=" .. tostring(d and d.remaining) .. " transport=" .. calls.transport)
end

-- ============================================================
-- D. exhausted ⇒ CLOSED removal + new Lease requested (coexistence without overwrite)
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    -- consume 8 more to exhaust the current Lease (remaining 8->0)
    for _ = 1, 8 do algorithm.check(conf, key) end
    local st = lease.stats()
    ok("D-exhausted-closed", st.leases == 1 and st.closed == 1
       and st.local_remaining == 0,
       "leases=" .. st.leases .. " closed=" .. st.closed)
    -- next request triggers a new Lease; granted=5 returned (partial grant, also covers E)
    calls.transport = 0
    transport_ret = { granted = 5, tokens = 80, wait = 0.5 }
    local d = algorithm.check(conf, key)
    st = lease.stats()
    ok("D-regrant-partial", d ~= nil and d.allowed == true and d.remaining == 4
       and calls.transport == 1 and st.leases == 2 and st.closed == 1
       and st.active == 1 and st.local_remaining == 4,
       "rem=" .. tostring(d and d.remaining) .. " leases=" .. st.leases)
    -- Gate 3 change: terminal-state objects are released immediately (diagnostic table removed) ⇒ the
    -- original "closed Lease object still in the full table" assertion becomes counter closure
    -- (closed=1, lease count closes, identity holds)
    ok("D-closed-counted",
       st.leases == st.closed + st.expired + st.active
       and st.granted == st.consumed + st.local_remaining + st.discarded_tokens
       and #lease._pools[key].active == 1
       and lease._pools[key].active[1].lease_id ~= nil,
       "leases=" .. st.leases .. " closed=" .. st.closed
       .. " active=" .. #lease._pools[key].active)
end

-- ============================================================
-- F. granted=0 ⇒ 429 (wait passthrough, no registration)
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    lease.reset(); calls.transport = 0
    transport_ret = { granted = 0, tokens = 0.5, wait = 0.7 }
    local d = algorithm.check(conf, key)
    ok("F-insufficient-429", d ~= nil and d.allowed == false
       and d.retry_after == 0.7 and d.remaining == 0
       and calls.transport == 1 and lease.stats().leases == 0,
       tostring(d and d.retry_after) .. "/" .. calls.transport)
    -- wait<=0 ⇒ floor of 1 (existing contract)
    transport_ret = { granted = 0, tokens = 0, wait = 0 }
    local d2 = algorithm.check(conf, key)
    ok("F-insufficient-wait-floor", d2.allowed == false and d2.retry_after == 1,
       tostring(d2.retry_after))
end

-- ============================================================
-- G/H. explicit error and uncertain ⇒ fault branch (nil, err, no registration, no retry)
-- ============================================================
do
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    lease.reset(); calls.transport = 0

    transport_ret, transport_err = nil, "LEASE_EXISTS: lease already exists"
    local d, err = algorithm.check(conf, key)
    ok("G-explicit-fault", d == nil and type(err) == "string" and err ~= ""
       and calls.transport == 1 and lease.stats().leases == 0,
       tostring(d) .. "/" .. tostring(err) .. "/" .. calls.transport)

    calls.transport = 0
    transport_ret, transport_err = nil, "timeout"
    local d2, err2 = algorithm.check(conf, key)
    ok("H-uncertain-fault", d2 == nil and type(err2) == "string" and err2 ~= ""
       and calls.transport == 1 and lease.stats().leases == 0,
       tostring(d2) .. "/" .. tostring(err2) .. "/" .. calls.transport)
end

-- ============================================================
-- I. config change ⇒ pool_key fingerprint isolation
-- ============================================================
do
    lease.reset()
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    local c1 = base_conf()
    local k1 = algorithm.build_key(c1)
    algorithm.check(c1, k1)
    local c2 = base_conf(); c2.limit = 200   -- fingerprint changes ⇒ new key
    local k2 = algorithm.build_key(c2)
    ok("I-fingerprint-isolates", k1 ~= k2 and lease._pools[k2] == nil
       and #lease._pools[k1].active == 1,
       k1 .. " vs " .. k2)
    -- header dimension change also isolates (fingerprint inputs include limit_by/header_name)
    local c3 = base_conf(); c3.limit_by = { "ip", "header" }; c3.header_name = "X-K"
    local k3 = algorithm.build_key(c3)
    ok("I-dim-change-isolates", k3 ~= k1, k1 .. " vs " .. k3)
end

-- ============================================================
-- J. multi rules ⇒ GRANT_MULTI, no Lease touched
-- ============================================================
do
    lease.reset(); calls.grant, calls.grant_multi, calls.transport = 0, 0, 0
    grant_multi_ret = { ok = 1, buckets = { { tokens = 99, wait = 0 }, { tokens = 99, wait = 0 } } }
    local conf = {
        namespace = "rl", fault_tolerant = false,
        rules = { { limit = 100, window = 3600, limit_by = { "ip" } },
                  { limit = 50,  window = 3600, limit_by = { "ip" } } },
        redis = { key_prefix = "kong:rl" },
    }
    algorithm.build_group_keys(conf)
    local d = algorithm.check_multi(conf)
    ok("J-multi-uses-grant-multi", d ~= nil and d.allowed == true
       and calls.grant_multi == 1 and calls.transport == 0
       and lease.stats().leases == 0,
       tostring(d and d.allowed) .. "/multi=" .. calls.grant_multi)
end

-- ============================================================
-- K/L/M. Gate 3 additions: MAX_POOLS degraded / single in-flight degraded / concurrent burst (coroutine model)
-- ============================================================
do -- K: MAX_POOLS at cap with no evictable empty pool ⇒ pool_cap degraded direct path (no 429/no 503, no registration)
    lease.reset()
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 1
    local c1 = base_conf()
    local k1 = algorithm.build_key(c1)
    algorithm.check(c1, k1)                        -- k1 creates a Pool (ACTIVE)
    local c2 = base_conf(); c2.limit = 200         -- different key ⇒ second Pool
    local k2 = algorithm.build_key(c2)
    calls.grant, calls.transport, calls.warn = 0, 0, 0
    local d = algorithm.check(c2, k2)              -- NEED_GRANT ⇒ at cap ⇒ degraded
    ok("K-poolcap-direct-degrade",
       d ~= nil and d.allowed == true and d.remaining == 0
       and calls.grant == 1 and calls.transport == 0
       and calls.warn == 1 and lease.stats().leases == 1,
       "d=" .. tostring(d and d.allowed) .. " grant=" .. calls.grant
       .. " warn=" .. calls.warn .. " leases=" .. lease.stats().leases)
    -- after k1's pool is exhausted into an empty pool, ensure_capacity evicts it to restore capacity (zero stock loss)
    local k1pool = lease._pools[k1]
    for _ = 1, 10 do lease.take(k1) end            -- exhaust k1's Lease
    lease.MAX_POOLS = 1
    local d2 = algorithm.check(c2, k2)             -- k1's empty pool evicted ⇒ k2 grants normally
    ok("K-poolcap-evict-then-grant",
       d2 ~= nil and d2.allowed == true and lease._pools[k1] == nil
       and lease._pools[k2] ~= nil and lease.stats().evicted == 1
       and calls.transport == 1,
       "d2=" .. tostring(d2 and d2.allowed) .. " transport=" .. calls.transport)
    lease.MAX_POOLS = saved
end

do -- L: single in-flight flag set ⇒ concurrent request degraded to direct path (no registration, Plan B)
    lease.reset()
    calls.grant, calls.transport = 0, 0
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    lease._inflight[key] = true                    -- simulate an in-flight GRANT (no-yield scenario)
    local d = algorithm.check(conf, key)
    lease._inflight[key] = nil
    ok("L-inflight-direct-degrade",
       d ~= nil and d.allowed == true and d.remaining == 0
       and calls.grant == 1 and calls.transport == 0
       and lease.stats().leases == 0,
       "d=" .. tostring(d and d.allowed) .. " grant=" .. calls.grant)
    -- direct-path requests stay out of the Lease ledger: identity and count closure still hold
    ok("L-direct-out-of-ledger", lease.invariants())
end

do -- M: concurrent burst (Lua coroutine interleaving model, yield points inside transport; not a real OpenResty verification)
    lease.reset()
    calls.grant, calls.transport = 0, 0
    local conf = base_conf()
    local key = algorithm.build_key(conf)
    transport_ret = { granted = 10, tokens = 90, wait = 0 }

    local N = 20
    local TICKS = 5
    lease._transport = function(...)
        coroutine.yield("grant_inflight")          -- simulate cosocket yield xTICKS
        coroutine.yield("grant_inflight")
        coroutine.yield("grant_inflight")
        coroutine.yield("grant_inflight")
        coroutine.yield("grant_inflight")
        calls.transport = calls.transport + 1
        return transport_ret, transport_err
    end

    local cos = {}
    for i = 1, N do
        cos[i] = coroutine.create(function()
            return algorithm.check(conf, key)
        end)
    end
    local live, decisions = N, {}
    while live > 0 do
        for i = 1, N do
            if coroutine.status(cos[i]) ~= "dead" then
                local okr, d = coroutine.resume(cos[i])
                if not okr then
                    decisions[#decisions + 1] = { err = tostring(d) }
                    live = live - 1
                elseif coroutine.status(cos[i]) == "dead" then
                    decisions[#decisions + 1] = d
                    live = live - 1
                end
            end
        end
    end
    lease._transport = nil

    local st = lease.stats()
    local all_allowed, n_direct_expected = true, true
    for i = 1, N do
        local d = decisions[i]
        if not (d and d.allowed == true) then all_allowed = false end
    end
    ok("M-concurrent-all-allowed", all_allowed,
       "allowed=" .. tostring(all_allowed))
    ok("M-single-inflight-grant",
       calls.transport == 1 and calls.grant == N - 1,
       "transport=" .. calls.transport .. " direct=" .. calls.grant)
    ok("M-active-bound-one",
       st.active == 1 and st.leases == 1 and st.local_remaining == 9,
       "active=" .. st.active .. " leases=" .. st.leases
       .. " rem=" .. st.local_remaining)
    ok("M-ledger-identity",
       st.granted == st.consumed + st.local_remaining + st.discarded_tokens
       and lease.invariants(),
       "g=" .. st.granted .. " c=" .. st.consumed .. " o=" .. st.local_remaining)
end

do -- N: deterministic concurrency (Gate 3 review-fix verification) — B triggers capacity reclamation while A's GRANT yields:
    -- A is not reclaimed, the in-flight GRANT occupies a pool slot ⇒ final Pool count does not exceed the cap
    lease.reset()
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 2
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    local confA = base_conf()
    local keyA = algorithm.build_key(confA)

    -- two-phase stub: park=false returns directly (epoch 1); park=true yields first (simulating a cosocket suspension)
    local transport_calls_N = 0
    local park = false
    lease._transport = function(...)
        transport_calls_N = transport_calls_N + 1
        if park then
            coroutine.yield("grant_inflight")
        end
        return transport_ret, transport_err
    end

    -- Epoch 1: A grants normally creating a pool (count=1 < MAX=2), then exhausts into an empty pool
    local dA1 = algorithm.check(confA, keyA)
    for _ = 1, 10 do lease.take(keyA) end
    ok("N-epoch1-empty-pool",
       dA1 ~= nil and dA1.allowed == true and lease.pool_count() == 1
       and #lease._pools[keyA].active == 0,
       "count=" .. lease.pool_count())

    -- A re-grants: count(1) < MAX(2) ⇒ no eviction triggered ⇒ Pool A exists, inflight set, suspended
    park = true
    local coA = coroutine.create(function()
        return algorithm.check(confA, keyA)
    end)
    coroutine.resume(coA)
    local poolA_ref = lease._pools[keyA]
    ok("N-parked-inflight",
       coroutine.status(coA) == "suspended"
       and lease.grant_in_flight(keyA) == true
       and poolA_ref ~= nil and #poolA_ref.active == 0,
       "status=" .. coroutine.status(coA)
       .. " inflight=" .. tostring(lease.grant_in_flight(keyA)))

    -- directly create empty pool C (test-register primitive; count=2=MAX)
    local keyC = "kong:rl:{n:c:ip=10.0.0.1}"
    lease.register(keyC, "id-c", 5)
    for _ = 1, 5 do lease.take(keyC) end
    ok("N-pool-c-created", lease.pool_count() == 2, "count=" .. lease.pool_count())

    -- B triggers capacity check: count(2) + in-flight new key (0, A reuses its original pool and occupies nothing) = 2 >= MAX(2)
    -- ⇒ evict empty pool C (skipping in-flight A) ⇒ count(1)+0 < 2 ⇒ B uses the last pool slot and grants normally (no pre-review erroneous degradation)
    local confB = base_conf(); confB.limit = 200
    local keyB = algorithm.build_key(confB)
    calls.grant, calls.warn = 0, 0
    local dB = algorithm.check(confB, keyB)
    ok("N-b-uses-last-slot-not-degraded",
       dB ~= nil and dB.allowed == true and dB.remaining == 9
       and calls.grant == 0 and calls.warn == 0 and transport_calls_N == 3
       and lease._pools[keyC] == nil and lease._pools[keyA] == poolA_ref
       and lease._pools[keyB] ~= nil
       and lease.pool_count() == 2 and lease.stats().evicted == 1,
       "grant=" .. calls.grant .. " transport=" .. transport_calls_N
       .. " count=" .. lease.pool_count()
       .. " evicted=" .. lease.stats().evicted)

    -- A resumes: GRANT returns ⇒ register reuses the original Pool (no rebuild) ⇒ total still <= cap
    park = false
    local okr, dA2 = coroutine.resume(coA)
    lease._transport = nil
    local st = lease.stats()
    ok("N-register-reuses-pool",
       okr and dA2 ~= nil and dA2.allowed == true and dA2.remaining == 9
       and lease._pools[keyA] == poolA_ref
       and lease.pool_count() == 2
       and lease.pool_count() <= lease.MAX_POOLS,
       "dA2=" .. tostring(dA2 and dA2.allowed)
       .. " count=" .. lease.pool_count())
    ok("N-invariants-with-bound", lease.invariants(),
       tostring(lease.invariants()))
    ok("N-ledger-identity",
       st.granted == st.consumed + st.local_remaining + st.discarded_tokens,
       "g=" .. st.granted .. " c=" .. st.consumed
       .. " o=" .. st.local_remaining .. " d=" .. st.discarded_tokens)
    lease.MAX_POOLS = saved
end

do -- O: in-flight slot reservation only applies to new Pool Keys (review fix) — two new Keys grant concurrently and
    -- occupy two pool slots, a third new Key correctly degrades to the direct path; final Pool count <= MAX
    lease.reset()
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 2
    transport_ret = { granted = 10, tokens = 90, wait = 0 }
    lease._transport = function(...)
        coroutine.yield("grant_inflight")
        return transport_ret, transport_err
    end
    local confA = base_conf()
    local keyA = algorithm.build_key(confA)
    local confB = base_conf(); confB.limit = 200
    local keyB = algorithm.build_key(confB)
    local confC = base_conf(); confC.limit = 300
    local keyC = algorithm.build_key(confC)

    local coA = coroutine.create(function() return algorithm.check(confA, keyA) end)
    local coB = coroutine.create(function() return algorithm.check(confB, keyB) end)
    coroutine.resume(coA)   -- suspended: new Key A occupies slot 1
    coroutine.resume(coB)   -- ensure: 0+1 < 2 ⇒ grant allowed, suspended: occupies slot 2
    calls.grant, calls.warn = 0, 0
    local dC = algorithm.check(confC, keyC)   -- ensure: 0+2 >= 2 ⇒ degraded to direct path
    ok("O-third-key-degraded",
       dC ~= nil and dC.allowed == true and dC.remaining == 0
       and calls.grant == 1 and calls.warn == 1
       and coroutine.status(coA) == "suspended"
       and coroutine.status(coB) == "suspended"
       and lease.pool_count() == 0,
       "grant=" .. calls.grant .. " count=" .. lease.pool_count())
    -- the two in-flight GRANTs each register a new pool ⇒ final Pool count = MAX (does not exceed the cap)
    local rA = coroutine.resume(coA)
    local rB = coroutine.resume(coB)
    lease._transport = nil
    local st = lease.stats()
    ok("O-final-count-bounded",
       rA and rB and lease.pool_count() == 2
       and lease.pool_count() <= lease.MAX_POOLS
       and lease._pools[keyA] ~= nil and lease._pools[keyB] ~= nil,
       "count=" .. lease.pool_count())
    ok("O-invariants-with-bound", lease.invariants())
    ok("O-ledger-identity",
       st.granted == st.consumed + st.local_remaining + st.discarded_tokens,
       "g=" .. st.granted .. " c=" .. st.consumed
       .. " o=" .. st.local_remaining .. " d=" .. st.discarded_tokens)
    lease.MAX_POOLS = saved
end

redis_mod.grant, redis_mod.grant_multi = orig_grant, orig_grant_multi

print("===== Summary: PASS=" .. pass .. " FAIL=" .. fail .. " =====")
if fail > 0 then os.exit(1) end
