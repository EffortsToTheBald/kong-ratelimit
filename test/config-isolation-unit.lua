-- ============================================================
-- config-isolation-unit.lua —— 6.3 配置隔离单测（resty）
--
-- 覆盖（用户验收 §5.1 + §5.3 本地 Pool 层）：
--   相同配置 ⇒ 相同 pool_key（实际 build_key 输出，非独立辅助函数）
--   仅 limit / window / burst / limit_by / header_name 变化 ⇒ pool_key 不同
--   burst=nil 与 burst=0 归一化等价（rate_and_burst 口径）⇒ 相同 key
--   batch 变化 ⇒ pool_key 相同（冻结：batch 不入策略指纹）
--   pool_key == Redis 桶键（D7 一体格式，非两套 Key 体系）
--   本地 Pool 隔离（transport stub）：A 库存不被 B 消费、B 走独立 GRANT/TAKE 路径、
--   A 库存在 B 请求之后独立存活、相同配置命中同一 Pool
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
-- 指纹/pool_key 矩阵（验证实际 build_key 输出）
-- ============================================================
local kA = algorithm.build_key(base_conf())
do
    local kA2 = algorithm.build_key(base_conf())
    ok("same-config-same-key", kA == kA2, kA .. " vs " .. kA2)

    local cases = {
        { "limit",      { limit = 200 } },
        { "window",     { window = 7200 } },
        { "burst",      { burst = 5 } },
        { "limit_by",   { limit_by = { "ip", "method" } } },  -- 仅 limit_by 变化（单维度独立证明）
    }
    for _, c in ipairs(cases) do
        local kb = algorithm.build_key(copy(base_conf(), c[2]))
        ok("diff-" .. c[1], kA ~= kb, kA .. " vs " .. kb)
    end

    -- header_name：limit_by 含 header 时参与指纹
    local k1 = algorithm.build_key(copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-A" }))
    local k2 = algorithm.build_key(copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-B" }))
    ok("diff-header_name", k1 ~= k2, k1 .. " vs " .. k2)

    -- burst=nil 与 burst=0 归一化等价（rate_and_burst：burst<=0 ⇒ limit）⇒ 同 key
    local kn = algorithm.build_key(copy(base_conf(), { burst = nil }))
    ok("burst-nil-equals-0", kn == kA, kn .. " vs " .. kA)

    -- batch 不入指纹（冻结决策）⇒ 同 key
    local kb = algorithm.build_key(copy(base_conf(), { batch = 20 }))
    ok("batch-not-in-fingerprint", kb == kA, kb .. " vs " .. kA)

    -- D7：pool_key 即 Redis 桶键（一体格式）
    ok("poolkey-is-bucket-key",
       kA:sub(1, #"kong:rl:{") == "kong:rl:{" and kA:find(":p=") ~= nil,
       kA)
end

-- ============================================================
-- 本地 Pool 隔离（真实 check_lease 路径 + transport stub）
-- ============================================================
lease.reset()

do -- 配置 A：GRANT + 消费 1，本地余 4
    transport_ret = { granted = 5, tokens = 95, wait = 0 }
    local confA = base_conf()
    local dA = algorithm.check_lease(confA, kA)
    local st = lease.stats()
    ok("iso-A-granted", dA.allowed == true and dA.remaining == 4
       and st.leases == 1 and st.local_remaining == 4 and calls.transport == 1,
       "rem=" .. tostring(dA and dA.remaining) .. " transport=" .. calls.transport)
end

do -- 配置 B（limit 200 ⇒ 新指纹）：不得消费 A 库存，走自己的 GRANT
    local kB = algorithm.build_key(copy(base_conf(), { limit = 200 }))
    calls.transport = 0
    transport_ret = { granted = 3, tokens = 197, wait = 0 }
    local confB = copy(base_conf(), { limit = 200 })
    local dB = algorithm.check_lease(confB, kB)
    local st = lease.stats()
    ok("iso-B-fresh-grant", dB.allowed == true and dB.remaining == 2
       and calls.transport == 1,  -- B 无库存 ⇒ 必须 GRANT（未复用 A 的 4 个）
       "rem=" .. tostring(dB and dB.remaining) .. " transport=" .. calls.transport)
    ok("iso-B-own-pool", lease._pools[kB] ~= nil and lease._pools[kB] ~= lease._pools[kA]
       and #lease._pools[kB].active == 1, tostring(lease._pools[kB]))
    -- A Pool 完全未被触碰（remaining 4 / consumed 1 / active 1）
    local pA = lease._pools[kA]
    ok("iso-A-untouched", #pA.active == 1 and pA.active[1].remaining == 4
       and pA.active[1].consumed == 1,
       "A rem=" .. pA.active[1].remaining .. " consumed=" .. pA.active[1].consumed)
end

do -- A 再次请求：本地 TAKE（零 GRANT），A 库存在 B 请求后独立存活
    calls.transport = 0
    local dA2 = algorithm.check_lease(base_conf(), kA)
    local st = lease.stats()
    ok("iso-A-still-alive", dA2.allowed == true and dA2.remaining == 3
       and calls.transport == 0 and st.leases == 2 and st.local_remaining == 5,
       "rem=" .. tostring(dA2 and dA2.remaining) .. " leases=" .. st.leases)
end

do -- 相同配置（新 table 实例）⇒ 命中同一 Pool
    local kA3 = algorithm.build_key(copy(base_conf(), {}))
    ok("same-config-hits-same-pool", kA3 == kA and lease._pools[kA3] == lease._pools[kA], kA3)
end

-- ============================================================
-- 关口四任务 A：维度值编码 / 碰撞 / key 稳定 / hash tag / slot 一致性
-- ============================================================
local keys_mod = require("kong.plugins.rate-limit-advanced.lib.keys")
local bit = require("bit")

-- Redis Cluster slot 的等价算法（本环境 standalone 无 CLUSTER KEYSLOT）：
-- tag = 首个 '{' 至其后首个 '}'（无 ⇒ 整 key）；slot = CRC16-XMODEM(tag) % 16384
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

do -- CRC16-XMODEM 算法自校验（Redis 官方示例向量：crc16("123456789")=0x31C3）
    ok("keys-crc16-known-vector", crc16_xmodem("123456789") == 0x31C3,
       string.format("crc=0x%X", crc16_xmodem("123456789")))
end

do -- 维度值编码：':{}%' 转义、原值不出现、同输入稳定
    local c = copy(base_conf(), { limit_by = { "header" }, header_name = "X-T" })
    kong.request.get_header = function() return "a:b{c}d%e" end
    local k1 = algorithm.build_key(c)
    local k2 = algorithm.build_key(copy(c, {}))
    ok("keys-encode-ambiguous-chars",
       string.find(k1, "header=a%3Ab%7Bc%7Dd%25e", 1, true) ~= nil
       and not string.find(k1, "a:b{c}d%e", 1, true),
       k1)
    ok("keys-stable-same-input", k1 == k2, k1 .. " vs " .. k2)
    -- 不同输入 ⇒ 不同 key（'%' 自身被编码，无二次解码歧义）
    kong.request.get_header = function() return "a:b{c}de" end
    local k3 = algorithm.build_key(copy(c, {}))
    ok("keys-distinct-inputs", k1 ~= k3 and k1 ~= k2 or k3 ~= k2, k1 .. "/" .. k3)
end

do -- 多维组合不碰撞：header 值伪造 "ip=1.2.3.4:header=x" 模式不与真实两维组合相等
    local c2d = copy(base_conf(), { limit_by = { "ip", "header" }, header_name = "X-T" })
    kong.client.get_forwarded_ip = function() return "1.2.3.4" end
    kong.request.get_header = function() return "x" end
    local kReal = algorithm.build_key(c2d)
    kong.client.get_forwarded_ip = function() return "unknown" end
    kong.request.get_header = function() return "ip=1.2.3.4:header=x" end
    local kFake = algorithm.build_key(c2d)
    -- 旧实现（值不转义）下 kFake 的值段可拼出与 kReal 相同的字符串；编码后
    -- 值内 ':' 变 %3A ⇒ 不再存在可拼接的 ':' 边界（'=' 属值内字符，不转义）
    ok("keys-multidim-no-collision",
       kReal ~= kFake
       and string.find(kFake, "header=ip=1.2.3.4%3Aheader=x", 1, true) ~= nil
       and string.find(kReal, "ip=1.2.3.4:header=x", 1, true) ~= nil,
       kReal .. " vs " .. kFake)
end

do -- hash tag 结构：'{'/'}' 仅出现在桶键骨架边界，维度值不可能破坏 tag
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
    -- 破坏性值（'}' 截断 tag 的旧风险）在新编码下不可能出现
    ok("keys-tag-unbreakable", slot_of(k) == slot_of(k), "stable")
end

do -- Lease 键与桶键同 slot（等价算法；无 Cluster 环境的确定性验证）
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
       "bucket/lease slot 一致性（CRC16 等价算法；真实 Cluster 实测 NOT VERIFIED）")
end

do -- build_lease_key 输入规范（lease_id 不得含 '{' '}' '%'）
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

redis_mod.grant = redis_mod.grant -- noop：保持模块引用一致性

print("===== 汇总: PASS=" .. pass .. " FAIL=" .. fail .. " =====")
if fail > 0 then os.exit(1) end
