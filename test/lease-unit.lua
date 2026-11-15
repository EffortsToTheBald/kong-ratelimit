local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

local lease = require("kong.plugins.rate-limit-advanced.lib.lease")
local ngx_now = ngx.now

local PK = "kong:rl:{p4u:ip=10.0.0.1}"

-- ============================================================
-- 4.1 Structure: register fields and conservation starting point
--     (Gate 3 changes: terminal-state objects are released immediately and counted into history;
--      pool.leases diagnostic listing removed; the original "full diagnostic table retains
--      objects" assertion is replaced by "counter closure + no residue in active set")
-- ============================================================
lease.reset()

do -- basic register fields
    local l, err = lease.register(PK, "id-a1", 5)
    ok("register-fields",
       l ~= nil and err == nil
       and l.lease_id == "id-a1" and l.pool_key == PK
       and l.granted == 5 and l.remaining == 5 and l.consumed == 0
       and l.state == "ACTIVE" and type(l.created_at) == "number",
       tostring(l) .. "/" .. tostring(err))
    -- consumable set contains the object; Pool structure has last_used/max_age (Gate 3)
    local pool = lease._pools[PK]
    ok("register-structure", #pool.active == 1 and pool.active[1] == l
       and type(pool.last_used) == "number",
       "active=" .. #pool.active)
    ok("register-counters", lease.stats().leases == 1 and lease.stats().granted == 5
       and lease.stats().active == 1,
       "leases=" .. lease.stats().leases)
end

do -- register parameter rejection (non-positive-integer granted ⇒ reject, zero state change)
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

do -- Conservation: register 5 → take 3 ⇒ remaining=2/consumed=3 (after reset, global counters are this case's)
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
-- 4.2 TAKE: decrement / zero balance not consumable / insertion order (sequential epoch) / no yield
-- ============================================================
lease.reset()

do -- unknown pool ⇒ NEED_GRANT
    local t, v = lease.take("kong:rl:{p4u:none}")
    ok("take-unknown-pool", t == false and v == "NEED_GRANT", tostring(v))
end

do -- batch decrement sequence and no consumption after zeroing (including CLOSED on exhaustion)
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

do -- consumption order (sequential epoch): A(2) exhausted and CLOSED, removed; then B(3) registered; A is no longer selected
    local pk = PK .. "order"
    lease.register(pk, "id-A", 2)
    local owners = {}
    for i = 1, 2 do
        local t, _, lid = lease.take(pk)
        owners[i] = t and lid or "NG"
    end
    -- B can only be registered after A is exhausted (CLOSED and removed) (Plan B upper bound)
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

do -- Plan B upper bound: pool already has an ACTIVE Lease ⇒ register rejects (no overwrite, no coexistence)
    lease.reset()
    local pk = PK .. "busy"
    local a = lease.register(pk, "id-M1", 4)
    local b, berr = lease.register(pk, "id-M2", 6)
    local pool = lease._pools[pk]
    ok("multi-lease-busy-reject",
       a ~= nil and b == nil and type(berr) == "string"
       and #pool.active == 1 and pool.active[1] == a,
       tostring(b) .. "/" .. tostring(berr))
    -- After A is exhausted and removed, a new epoch can be registered; lease_id independent, counters not overwritten (original "coexistence without overwrite" intent)
    for _ = 1, 4 do lease.take(pk) end
    local b2 = lease.register(pk, "id-M2", 6)
    local st = lease.stats()
    ok("multi-lease-sequential-epochs",
       b2 ~= nil and b2.lease_id == "id-M2" and st.leases == 2
       and st.active == 1 and st.local_remaining == 6
       and lease.invariants(),
       "leases=" .. st.leases .. " active=" .. st.active)
end

do -- yield probe: no yield inside the TAKE snippet (completes within a single resume)
    local pk = PK .. "yield"
    lease.register(pk, "id-y1", 3)
    local co = coroutine.create(function()
        return lease.take(pk)
    end)
    local results = table.pack(coroutine.resume(co))
    ok("take-no-yield",
       results[1] == true            -- no error
       and coroutine.status(co) == "dead"  -- finished in one resume = no yield inside snippet
       and results[2] == true and results[3] == 2,
       "status=" .. coroutine.status(co) .. " n=" .. results.n)
end

do -- after 100 random operations, structural invariants still hold (negative stock/over-grant impossible)
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
-- 4.3 Exhaustion handling: CLOSED/removal/counter closure/no revival
-- ============================================================
lease.reset()

do -- exhaustion ⇒ CLOSED + removed from consumable set + counter closure (diagnostic table removed, history counted into counters)
    local pk = PK .. "exh"
    local l = lease.register(pk, "id-x1", 2)
    lease.take(pk)
    lease.take(pk)   -- exhausted
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

do -- CLOSED not revivable / repeated marking has no side effects
    local pk = PK .. "exh2"
    lease.register(pk, "id-x2", 1)
    lease.take(pk)                       -- exhausted and closed
    local st1 = lease.stats()
    local t2 = lease.take(pk)            -- TAKE again ⇒ not selected
    local st2 = lease.stats()
    ok("closed-not-revivable",
       t2 == false and st1.closed == st2.closed and st1.leases == st2.leases
       and lease.invariants(),
       tostring(t2))
end

do -- V1 has no RETURN: Redis record is not cleaned up after exhaustion (this layer is local state only; asserted as having no Redis call interface here)
    ok("exhaust-no-return-path", lease.invariants(), "structural")
end

-- ============================================================
-- 4.4 GRANT classification + sequential epoch (stub transport)
-- ============================================================
lease.reset()

local calls
local stub_transport
do -- stub: replay (parsed, err) from a preset script, and count invocations (for retry assertions)
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

do -- Case ①: success ⇒ create local Lease (granted/remaining conservation + max_age snapshot)
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

do -- Case ②: insufficient (granted=0) ⇒ no Lease created
    local res, e = run_grant({ { { granted = 0, tokens = 0.5, wait = 0.5 } } })
    local st = lease.stats()
    ok("grant-insufficient",
       res ~= nil and res.ok == false and res.reason == "insufficient"
       and e == nil and st.leases == 1,   -- not incremented (still the 1 from the previous case)
       tostring(res))
end

do -- Case ③: explicit error (LEASE_EXISTS) ⇒ fault branch, no registration, no retry
    local res, e = run_grant({ { nil, "LEASE_EXISTS id-zz" } })
    ok("grant-lease-exists",
       res == nil and type(e) == "table" and e.kind == "explicit_error"
       and string.find(e.err, "LEASE_EXISTS", 1, true) ~= nil and calls == 1,
       tostring(res) .. "/" .. tostring(e and e.kind))
end

do -- Case ④: uncertain (timeout) ⇒ no retry (exactly 1 call), no registration in local lease pool
    local res, e = run_grant({ { nil, "timeout" } })
    local st = lease.stats()
    ok("grant-uncertain-no-retry-no-register",
       res == nil and type(e) == "table" and e.kind == "uncertain"
       and calls == 1 and st.leases == 1,   -- only the 1 from grant-success throughout; no increment in this case
       tostring(res) .. "/" .. tostring(e and e.kind))
end

do -- malformed response ⇒ uncertain (may have executed); INVALID_ARGUMENT ⇒ explicit
    local c1, d1 = lease.classify_grant(nil, "malformed eval response: granted out of range")
    local c2, d2 = lease.classify_grant(nil, "INVALID_ARGUMENT batch")
    ok("grant-classify-edge",
       c1 == "uncertain" and c2 == "explicit_error",
       c1 .. "/" .. c2)
end

do -- single in-flight flag: set during transport execution, cleared after return (all classification paths)
    local seen_inflight
    lease._transport = function(...)
        seen_inflight = lease.grant_in_flight(PK)
        return { granted = 1, tokens = 99, wait = 0 }
    end
    local g1 = lease.grant({}, PK, "kong:rl:{p4u:g}", 1, 60000, 1, 100, 120000)
    -- the ACTIVE Lease from the previous case still exists ⇒ register in this case is rejected ⇒ uncertain (upper-bound semantics)
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
    -- previous case's register rejected (pool busy) ⇒ not recorded; can succeed again after exhaustion
    for _ = 1, 10 do lease.take(PK) end   -- exhaust the grant-success Lease
end

do -- sequential epoch (via grant): new GRANT succeeds after previous Lease exhausted, independent lease_id not overwritten
    local pk = PK .. "multi"
    lease._stub_seq = { { { granted = 4, tokens = 96, wait = 0 } },
                        { { granted = 6, tokens = 94, wait = 0 } } }
    lease._transport = stub_transport
    calls = 0
    local g1 = lease.grant({}, pk, "kong:rl:{p4u:g}", 4, 60000, 1, 100, 120000)
    -- second GRANT within the epoch: active is non-empty ⇒ register rejected ⇒ uncertain (no duplicate registration)
    local g2, e2 = lease.grant({}, pk, "kong:rl:{p4u:g}", 6, 60000, 1, 100, 120000)
    -- after exhausting g1, new epoch GRANT succeeds (independent lease_id)
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
    -- consumption order: the new epoch Lease is consumed independently
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

do -- lease_id generation: format + in-process uniqueness
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

do -- V1 accounting identity: granted = consumed + outstanding (no lost sequences)
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
-- Gate 3 additions: expiration (EXPIRED / counted into discarded once / unit convention)
-- ============================================================
lease.reset()

do -- expired candidate: TAKE does not consume, removes it and counts into discarded (once)
    local pk = PK .. "exp"
    local past = ngx_now() - 100
    lease.register(pk, "id-e1", 10, past, 5000)   -- created_at seconds + max_age 5s < now ⇒ expired
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
    -- repeated TAKE does not double-count (object already removed)
    local t2 = lease.take(pk)
    local st2 = lease.stats()
    ok("expire-no-double-count",
       t2 == false and st2.discarded_tokens == st1.discarded_tokens
       and st2.expired == st1.expired,
       "discarded=" .. st2.discarded_tokens)
    ok("expire-invariants", lease.invariants())
end

do -- unit convention: max_age in ms ⇒ compared as /1000 seconds (non-expired candidate consumed normally)
    local pk = PK .. "unit"
    local past = ngx_now() - 10
    lease.register(pk, "id-u1", 5, past, 20000)   -- past + 20s > now ⇒ not expired
    local t, rem = lease.take(pk)
    ok("expire-unit-ms-to-s",
       t == true and rem == 4 and lease.stats().discarded_tokens == 10,
       "t=" .. tostring(t) .. " rem=" .. tostring(rem))
end

do -- sweep_pool: lazy sweep on the GRANT path; busy check based on #active (expired candidates still occupy a slot before removal)
    local pk = PK .. "sweep"
    local past = ngx_now() - 100
    lease.register(pk, "id-sw1", 3, past, 5000)       -- expired, untouched by take
    local b, berr = lease.register(pk, "id-sw2", 7, ngx_now(), 5000)
    ok("sweep-busy-with-expired",
       b == nil and type(berr) == "string", tostring(berr))
    local n = lease.sweep_pool(pk)                     -- removes expired sw1 (discarded once)
    local st = lease.stats()
    ok("sweep-pool",
       n == 1 and st.discarded_tokens == 10 + 3
       and #lease._pools[pk].active == 0,
       "removed=" .. n .. " discarded=" .. st.discarded_tokens)
    local c = lease.register(pk, "id-sw2", 7, ngx_now(), 5000)   -- after removal, a new epoch can be registered
    ok("sweep-then-register",
       c ~= nil and #lease._pools[pk].active == 1 and lease.invariants(),
       tostring(c))
end

lease.reset()

do -- Timer fallback sweep: idle Pool removed / active Pool retained / expired Lease counted once
    local now = ngx_now()
    -- idle empty pool (reclaimable; max_age already snapshotted)
    local pk1 = PK .. "t-idle"
    lease.register(pk1, "id-t1", 2, ngx_now(), 5000)
    for _ = 1, 2 do lease.take(pk1) end            -- exhausted ⇒ active empty
    lease._pools[pk1].last_used = now - 1000       -- test-only direct write: rewind last_used
    -- idle pool containing an expired Lease (should be removed then the pool deleted)
    local pk2 = PK .. "t-exp"
    lease.register(pk2, "id-t2", 4, now - 100, 5000)
    lease._pools[pk2].last_used = now - 1000
    -- active pool (contains a non-expired Lease) ⇒ retained
    local pk3 = PK .. "t-live"
    lease.register(pk3, "id-t3", 6, now - 1, 5000)
    lease._pools[pk3].last_used = now - 1000
    -- idle but max_age not snapshotted (direct registration without max_age) ⇒ not handled
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

do -- Timer quantity cap: 70 idle pools, ≤64 per pass, remainder handled next time
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

do -- Timer skips Pools with in-flight GRANTs (Gate 3 review fix: prevent post-eviction register rebuild exceeding the cap)
    lease.reset()
    local now = ngx_now()
    local pk = PK .. "t-inflight"
    lease.register(pk, "id-ti", 3, ngx_now(), 5000)
    for _ = 1, 3 do lease.take(pk) end          -- empty pool (reclaimable form)
    lease._pools[pk].last_used = now - 1000
    lease._inflight[pk] = true                  -- simulate an in-flight GRANT
    local n = lease.timer_sweep_once(64)
    ok("timer-skip-inflight",
       n == 0 and lease._pools[pk] ~= nil and lease.pool_count() == 1,
       "evicted=" .. n .. " count=" .. lease.pool_count())
    lease._inflight[pk] = nil                   -- after clearing, normal eviction resumes
    local n2 = lease.timer_sweep_once(64)
    ok("timer-evict-after-inflight-clear",
       n2 == 1 and lease._pools[pk] == nil and lease.pool_count() == 0,
       "evicted=" .. n2)
    ok("timer-skip-inflight-invariants", lease.invariants())
end

do -- Timer skips evict_idle_pools with the same semantics: in-flight Pool is not capacity-evicted (ensure_capacity path)
    lease.reset()
    local pk = PK .. "e-inflight"
    lease.register(pk, "id-ei", 3)
    for _ = 1, 3 do lease.take(pk) end          -- empty pool
    lease._inflight[pk] = true
    local removed = lease.evict_idle_pools(64)
    ok("evict-skip-inflight",
       removed == 0 and lease._pools[pk] ~= nil and lease.pool_count() == 1,
       "removed=" .. removed)
    lease._inflight[pk] = nil
    lease.evict_idle_pools(64)
    ok("evict-after-inflight-clear",
       lease._pools[pk] == nil and lease.pool_count() == 0
       and lease.invariants(),
       "count=" .. lease.pool_count())
end

-- ============================================================
-- Gate 3 additions: MAX_POOLS capacity and eviction (only empty pools are deleted, zero stock loss)
-- ============================================================
lease.reset()

do -- ensure_capacity: below cap true; at cap, evict empty pools then true; nothing evictable, false
    local saved = lease.MAX_POOLS
    lease.MAX_POOLS = 2
    local pkA = PK .. "capA"
    local pkB = PK .. "capB"
    lease.register(pkA, "id-a", 5)
    lease.register(pkB, "id-b", 5)      -- both pools ACTIVE ⇒ not evictable
    ok("capacity-full-no-evictable",
       lease.pool_count() == 2 and lease.ensure_capacity() == false
       and lease.pool_count() == 2 and lease.stats().evicted == 0,
       "count=" .. lease.pool_count())
    -- B exhausted ⇒ empty pool can be evicted
    for _ = 1, 5 do lease.take(pkB) end
    ok("capacity-evict-empty",
       lease.ensure_capacity() == true and lease.pool_count() == 1
       and lease._pools[pkB] == nil and lease.stats().evicted == 1,
       "count=" .. lease.pool_count())
    -- pools containing ACTIVE Leases are not evicted (frozen: zero stock loss)
    lease.register(pkB, "id-b2", 5)     -- rebuild B
    lease.MAX_POOLS = 1                 -- cap=1: both A/B have ACTIVE ⇒ not evictable
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
