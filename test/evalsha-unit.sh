#!/usr/bin/env bash
# ============================================================
# evalsha-unit.sh —— deterministic unit tests for the EVALSHA wrapper (stub redis client)
#
# Coverage: normal path/lazy load/NOSCRIPT self-heal/second NOSCRIPT failure/LOAD failure/
#           timeout triggers no LOAD/closed connection triggers no LOAD/timeout after lazy load
# Run: docker compose exec -T kong1 resty < test/evalsha-unit.lua (fed by this script)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
# resty does not support reading a script from stdin: docker cp it into a temp file to execute
docker compose cp test/evalsha-unit.lua kong1:/tmp/evalsha-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/evalsha-unit.lua <<'LUA'
local rm = require("kong.plugins.rate-limit-advanced.lib.redis")
local pass, fail = 0, 0

-- stub redis client: replay (res, err) for evalsha/script from a queue
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

-- 1) SHA cached ⇒ evalsha succeeds directly, zero LOAD
do
    local c = stub({ {"RES"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("cached-sha", res == "RES" and err == nil and #c.calls == 1 and c.calls[1] == "evalsha#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 2) SHA not cached ⇒ lazy load (script → evalsha succeeds)
do
    local c = stub({ {"sha1"}, {"RES"} })
    local e = new_entry(nil)
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("lazy-load", res == "RES" and e.sha == "sha1" and #c.calls == 2
       and c.calls[1] == "script#1" and c.calls[2] == "evalsha#2",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 3) NOSCRIPT ⇒ LOAD ⇒ retry succeeds (exactly once)
do
    local c = stub({ {"NOSCRIPT No matching script."}, {"sha1"}, {"RES"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("noscript-heal", res == "RES" and #c.calls == 3
       and c.calls[2] == "script#2" and c.calls[3] == "evalsha#3",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 4) still NOSCRIPT after retry ⇒ explicit failure, no second LOAD
do
    local c = stub({ {"NOSCRIPT No matching script."}, {"sha1"}, {"NOSCRIPT again."} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("double-noscript", res == nil and err ~= nil and #c.calls == 3,
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 5) LOAD failure ⇒ failure without retry
do
    local c = stub({ {nil, "LOADERR"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("load-fail", res == nil and err ~= nil and #c.calls == 1 and c.calls[1] == "script#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 6) timeout ⇒ no LOAD triggered (never treated as NOSCRIPT)
do
    local c = stub({ {nil, "timeout"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("timeout-no-load", res == nil and err == "timeout" and #c.calls == 1 and c.calls[1] == "evalsha#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 7) connection closed ⇒ no LOAD triggered
do
    local c = stub({ {nil, "closed"} })
    local e = new_entry("abc123")
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("closed-no-load", res == nil and err == "closed" and #c.calls == 1 and c.calls[1] == "evalsha#1",
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

-- 8) EVALSHA timeout after successful lazy load ⇒ failure without retry
do
    local c = stub({ {"sha1"}, {nil, "timeout"} })
    local e = new_entry(nil)
    local res, err = rm.evalsha(c, e, 1, "k")
    ok("lazy-then-timeout", res == nil and err == "timeout" and #c.calls == 2,
       tostring(res) .. "/" .. tostring(err) .. "/" .. table.concat(c.calls, ","))
end

print("RESULT: pass=" .. pass .. " fail=" .. fail)
LUA
