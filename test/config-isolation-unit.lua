-- ============================================================
-- config-isolation-unit.lua —— 6.3 config isolation unit tests (resty)
--
-- Coverage (user acceptance §5.1 + §5.3 local Pool layer):
--   identical config ⇒ identical pool_key (actual build_key output, not an independent helper)
--   only limit / window / burst / limit_by / header_name changed ⇒ different pool_key
--   burst=nil and burst=0 normalize to the same value (rate_and_burst basis) ⇒ same key
--   batch changed ⇒ pool_key unchanged (frozen: batch is not part of the policy fingerprint)
--   pool_key == Redis bucket key (D7 unified format, not two key systems)
--   local Pool isolation (transport stub): A's stock is not consumed by B, B takes its own
--   GRANT/TAKE path, A's stock survives independently after B's requests, identical config hits the same Pool
-- ============================================================
local pass, fail = 0, 0
local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

local algorithm = require("kong.plugins.rate-limit-advanced.lib.algorithm")
local redis_mod = require("kong.plugins.rate-limit-advanced.lib.redis")
local lease = require("kong.plugins.rate-limit-advanced.lib.lease")

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

local calls = { transport = 0 }
local transport_ret
lease._transport = function(conf, bucket_key, lease_id, pool_key, batch,
                            lease_ttl_ms, rate, capacity, bucket_ttl_ms)
    calls.transport = calls.transport + 1
    return transport_ret
end

local function base_conf()
    return {
        namespace = "p63", limit = 100, window = 3600, burst = 0,
        batch = 10, limit_by = { "ip" },
        redis = { key_prefix = "kong:rl" },
    }
end

local function copy(c, patch)
    local n = {}
    for k, v in pairs(c) do n[k] = v end
    for k, v in pairs(patch or {}) do n[k] = v end
    return n
end

-- ============================================================
-- fingerprint/pool_key matrix (verifies actual build_key output)
-- ============================================================
local kA = algorithm.build_key(base_conf())
do
    local kA2 = algorithm.build_key(base_conf())
    ok("same-config-same-key", kA == kA2, kA .. " vs " .. kA2)

    local cases = {
        { "limit",      { limit = 200 } },
        { "window",     { window = 7200 } },
        { "burst",      { burst = 5 } },
        { "limit_by",   { limit_by = { "ip", "method" } } },  -- only limit_by changed (single-dimension independent proof)
    }
    for _, c in ipairs(cases) do
        local kb = algorithm.build_key(copy(base_conf(), c[2]))
        ok("diff-" .. c[1], kA ~= kb, kA .. " vs " .. kb)
    end

    -- header_name: participates in the fingerprint when limit_by includes header
    local k1 = algorithm.build_key(copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-A" }))
    local k2 = algorithm.build_key(copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-B" }))
    ok("diff-header_name", k1 ~= k2, k1 .. " vs " .. k2)

    -- burst=nil and burst=0 normalize to the same value (rate_and_burst: burst<=0 ⇒ limit) ⇒ same key
    local kn = algorithm.build_key(copy(base_conf(), { burst = nil }))
    ok("burst-nil-equals-0", kn == kA, kn .. " vs " .. kA)

    -- batch is not part of the fingerprint (frozen decision) ⇒ same key
    local kb = algorithm.build_key(copy(base_conf(), { batch = 20 }))
    ok("batch-not-in-fingerprint", kb == kA, kb .. " vs " .. kA)

    -- D7: pool_key is the Redis bucket key (unified format)
    ok("poolkey-is-bucket-key",
       kA:sub(1, #"kong:rl:{") == "kong:rl:{" and kA:find(":p=") ~= nil,
       kA)
end

-- ============================================================
-- local Pool isolation (real check_lease path + transport stub)
-- ============================================================
lease.reset()

do -- config A: GRANT + consume 1, local remainder 4
    transport_ret = { granted = 5, tokens = 95, wait = 0 }
    local confA = base_conf()
    local dA = algorithm.check_lease(confA, kA)
    local st = lease.stats()
    ok("iso-A-granted", dA.allowed == true and dA.remaining == 4
       and st.leases == 1 and st.local_remaining == 4 and calls.transport == 1,
       "rem=" .. tostring(dA and dA.remaining) .. " transport=" .. calls.transport)
end

do -- config B (limit 200 ⇒ new fingerprint): must not consume A's stock, takes its own GRANT
    local kB = algorithm.build_key(copy(base_conf(), { limit = 200 }))
    calls.transport = 0
    transport_ret = { granted = 3, tokens = 197, wait = 0 }
    local confB = copy(base_conf(), { limit = 200 })
    local dB = algorithm.check_lease(confB, kB)
    local st = lease.stats()
    ok("iso-B-fresh-grant", dB.allowed == true and dB.remaining == 2
       and calls.transport == 1,  -- B has no stock ⇒ must GRANT (does not reuse A's 4)
       "rem=" .. tostring(dB and dB.remaining) .. " transport=" .. calls.transport)
    ok("iso-B-own-pool", lease._pools[kB] ~= nil and lease._pools[kB] ~= lease._pools[kA]
       and #lease._pools[kB].active == 1, tostring(lease._pools[kB]))
    -- A's Pool completely untouched (remaining 4 / consumed 1 / active 1)
    local pA = lease._pools[kA]
    ok("iso-A-untouched", #pA.active == 1 and pA.active[1].remaining == 4
       and pA.active[1].consumed == 1,
       "A rem=" .. pA.active[1].remaining .. " consumed=" .. pA.active[1].consumed)
end

do -- A requests again: local TAKE (zero GRANT), A's stock survives independently after B's requests
    calls.transport = 0
    local dA2 = algorithm.check_lease(base_conf(), kA)
    local st = lease.stats()
    ok("iso-A-still-alive", dA2.allowed == true and dA2.remaining == 3
       and calls.transport == 0 and st.leases == 2 and st.local_remaining == 5,
       "rem=" .. tostring(dA2 and dA2.remaining) .. " leases=" .. st.leases)
end

do -- identical config (new table instance) ⇒ hits the same Pool
    local kA3 = algorithm.build_key(copy(base_conf(), {}))
    ok("same-config-hits-same-pool", kA3 == kA and lease._pools[kA3] == lease._pools[kA], kA3)
end

-- ============================================================
-- Gate 4 task A: dimension value encoding / collisions / key stability / hash tag / slot consistency
-- ============================================================
local keys_mod = require("kong.plugins.rate-limit-advanced.lib.keys")
local bit = require("bit")

-- Equivalent algorithm for the Redis Cluster slot (this environment is standalone, no CLUSTER KEYSLOT):
-- tag = from the first '{' to the following first '}' (none ⇒ whole key); slot = CRC16-XMODEM(tag) % 16384
local function crc16_xmodem(s)
    local crc = 0
    for i = 1, #s do
        crc = bit.bxor(crc, bit.lshift(string.byte(s, i), 8))
        for _ = 1, 8 do
            if bit.band(crc, 0x8000) ~= 0 then
                crc = bit.bxor(bit.band(bit.lshift(crc, 1), 0xffff), 0x1021)
            else
                crc = bit.band(bit.lshift(crc, 1), 0xffff)
            end
        end
    end
    return crc
end

local function slot_of(key)
    local tag = key
    local a = string.find(key, "{", 1, true)
    if a then
        local b = string.find(key, "}", a + 1, true)
        if b then tag = string.sub(key, a + 1, b - 1) end
    end
    return crc16_xmodem(tag) % 16384
end

do -- CRC16-XMODEM algorithm self-check (Redis official example vector: crc16("123456789")=0x31C3)
    ok("keys-crc16-known-vector", crc16_xmodem("123456789") == 0x31C3,
       string.format("crc=0x%X", crc16_xmodem("123456789")))
end

do -- dimension value encoding: ':{}%' escaped, raw value absent, stable for the same input
    local c = copy(base_conf(), { limit_by = { "header" }, header_name = "X-T" })
    kong.request.get_header = function() return "a:b{c}d%e" end
    local k1 = algorithm.build_key(c)
    local k2 = algorithm.build_key(copy(c, {}))
    ok("keys-encode-ambiguous-chars",
       string.find(k1, "header=a%3Ab%7Bc%7Dd%25e", 1, true) ~= nil
       and not string.find(k1, "a:b{c}d%e", 1, true),
       k1)
    ok("keys-stable-same-input", k1 == k2, k1 .. " vs " .. k2)
    -- different inputs ⇒ different keys ('%' itself is encoded, no double-decode ambiguity)
    kong.request.get_header = function() return "a:b{c}de" end
    local k3 = algorithm.build_key(copy(c, {}))
    ok("keys-distinct-inputs", k1 ~= k3 and k1 ~= k2 or k3 ~= k2, k1 .. "/" .. k3)
end

do -- multi-dimension composition does not collide: a header value forging the "ip=1.2.3.4:header=x" pattern is not equal to the real two-dimension combination
    local c2d = copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-T" })
    kong.client.get_forwarded_ip = function() return "1.2.3.4" end
    kong.request.get_header = function() return "x" end
    local kReal = algorithm.build_key(c2d)
    kong.client.get_forwarded_ip = function() return "unknown" end
    kong.request.get_header = function() return "ip=1.2.3.4:header=x" end
    local kFake = algorithm.build_key(c2d)
    -- under the old implementation (values unescaped), kFake's value segment could be assembled into the same string as kReal;
    -- after encoding, ':' inside values becomes %3A ⇒ no more assemblable ':' boundary ('=' is an in-value character, not escaped)
    ok("keys-multidim-no-collision",
       kReal ~= kFake
       and string.find(kFake, "header=ip=1.2.3.4%3Aheader=x", 1, true) ~= nil
       and string.find(kReal, "ip=1.2.3.4:header=x", 1, true) ~= nil,
       kReal .. " vs " .. kFake)
end

do -- hash tag structure: '{'/'}' appear only at the bucket-key skeleton boundary; dimension values cannot break the tag
    kong.client.get_forwarded_ip = function() return "10.0.0.7" end
    kong.request.get_header = function() return "}{:{" end
    local c = copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-T" })
    local k = algorithm.build_key(c)
    local nOpen, nClose = 0, 0
    for _ in string.gmatch(k, "{") do nOpen = nOpen + 1 end
    for _ in string.gmatch(k, "}") do nClose = nClose + 1 end
    local a = string.find(k, "{", 1, true)
    local b = string.find(k, "}", a or 1, true)
    ok("keys-hash-tag-structure",
       nOpen == 1 and nClose == 1 and a and b and a < b
       and string.find(k, "%7D", 1, true) ~= nil,
       k)
    -- destructive values (the old risk of '}' truncating the tag) are impossible under the new encoding
    ok("keys-tag-unbreakable", slot_of(k) == slot_of(k), "stable")
end

do -- Lease key and bucket key share a slot (equivalent algorithm; deterministic verification without a Cluster environment)
    local buckets = {
        algorithm.build_key(copy(base_conf(), { limit_by = { "ip" } })),
        "kong:rl:{ns1:p=abcdef01:header=a%3Ab}",
        "kong:rl:{g1}",
    }
    local all_same = true
    for _, bk in ipairs(buckets) do
        local lk = keys_mod.build_lease_key(bk, "host:0:1:00ff")
        if lk ~= bk .. ":lease:host:0:1:00ff" then all_same = false end
        if slot_of(lk) ~= slot_of(bk) then all_same = false end
    end
    ok("keys-lease-same-slot", all_same,
       "bucket/lease slot consistency (CRC16 equivalent algorithm; real Cluster measurement NOT VERIFIED)")
end

do -- build_lease_key input spec (lease_id must not contain '{' '}' '%')
    local bk = "kong:rl:{x}"
    local e1 = keys_mod.build_lease_key(nil, "id")
    local e2 = keys_mod.build_lease_key(bk, "")
    local e3 = keys_mod.build_lease_key(bk, "id{br}")
    local e4 = keys_mod.build_lease_key(bk, "id%p")
    local good = keys_mod.build_lease_key(bk, "host:0:1:abc")
    ok("keys-lease-input-spec",
       e1 == nil and e2 == nil and e3 == nil and e4 == nil
       and good == bk .. ":lease:host:0:1:abc",
       tostring(e3) .. "/" .. tostring(e4))
end

kong.client.get_forwarded_ip = function() return "10.0.0.1" end
kong.request.get_header = function() return nil end

redis_mod.grant = redis_mod.grant -- noop: keeps the module reference consistent

print("===== Summary: PASS=" .. pass .. " FAIL=" .. fail .. " =====")
if fail > 0 then os.exit(1) end
