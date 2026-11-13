local rm = require("kong.plugins.rate-limit-advanced.lib.redis")
local pass, fail = 0, 0

-- stub redis client：按队列回放 evalsha/script 的 (res, err)
local function stub(seq)
    local i = 0
    local c = {}
    c.calls = {}
    function c:evalsha(sha, ...)
        i = i + 1
        table.insert(c.calls, "evalsha#" .. i)
        local s = seq[i] or {}
        return s[1], s[2]
    end
    function c:script(cmd, src)
        i = i + 1
        table.insert(c.calls, "script#" .. i)
        local s = seq[i] or {}
        return s[1], s[2]
    end
    return c
end

local function new_entry(sha)
    return { name = "t", src = "return 1", sha = sha }
end

local function ok(name, cond, detail)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL [" .. name .. "] " .. tostring(detail)) end
end

-- 1) SHA 已缓存 ⇒ evalsha 直接成功、零 LOAD
do
    local c = stub({ {"RES"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("cached-sha", res == "RES" and err == nil and #c.calls == 1 and c.calls[1] == "evalsha#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 2) SHA 未缓存 ⇒ 懒加载（script → evalsha 成功）
do
    local c = stub({ {"sha1"}, {"RES"} })
    local e = new_entry(nil)
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("lazy-load", res == "RES" and e.sha == "sha1" and #c.calls == 2
       and c.calls[1] == "script#1" and c.calls[2] == "evalsha#2",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 3) NOSCRIPT ⇒ LOAD ⇒ 重试成功（恰一次）
do
    local c = stub({ {nil, "NOSCRIPT No matching script."}, {"sha1"}, {"RES"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("noscript-heal", res == "RES" and #c.calls == 3
       and c.calls[2] == "script#2" and c.calls[3] == "evalsha#3",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 4) 重试后仍 NOSCRIPT ⇒ 明确失败、无第二次 LOAD
do
    local c = stub({ {nil, "NOSCRIPT No matching script."}, {"sha1"}, {nil, "NOSCRIPT again."} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("double-noscript", res == nil and err ~= nil and #c.calls == 3,
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 5) LOAD 失败 ⇒ 失败且不重试（SHA 未缓存 ⇒ 第一次调用是 script）
do
    local c = stub({ {nil, "LOADERR"} })
    local e = new_entry(nil)
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("load-fail", res == nil and err ~= nil and #c.calls == 1 and c.calls[1] == "script#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 6) 超时 ⇒ 不触发 LOAD（绝不当作 NOSCRIPT）
do
    local c = stub({ {nil, "timeout"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("timeout-no-load", res == nil and err == "timeout" and #c.calls == 1 and c.calls[1] == "evalsha#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 7) 连接断开 ⇒ 不触发 LOAD
do
    local c = stub({ {nil, "closed"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("closed-no-load", res == nil and err == "closed" and #c.calls == 1 and c.calls[1] == "evalsha#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 8) 懒加载成功后 EVALSHA 超时 ⇒ 失败且无重试
do
    local c = stub({ {"sha1"}, {nil, "timeout"} })
    local e = new_entry(nil)
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("lazy-then-timeout", res == nil and err == "timeout" and #c.calls == 2,
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

print("RESULT: pass=" .. pass .. " fail=" .. fail)