-- ============================================================
-- rate-limit-advanced / lib/store.lua
-- 本地库存（"零钱"）。
--
-- 优先用 ngx.shared（跨 worker 共享，按节点维度统计）；
-- 若 kong.conf 没配 lua_shared_dict，降级为 worker 内的 Lua 表——
-- 功能不中断，但每个 worker 各自持有一份库存，精度会下降。
--
-- 不变量：库存里的令牌都是从 Redis 全局桶"扣出来"的，
--         所以本地永远不可能凭空造出配额。
-- ============================================================
local _M = {}

local DICT_NAME = "kong_rl"
local FALLBACK_MAX_KEYS = 4096

local fallback = {}
local fallback_keys = 0

local function dict()
  if ngx and ngx.shared then
    return ngx.shared[DICT_NAME]
  end
  return nil
end

--- 本地库存是否走 shared dict（用于启动日志 / 设计文档说明）
function _M.backend()
  if dict() then
    return "shared_dict"
  end
  return "worker_table"
end

--- 原子地消耗 1 个库存令牌。
-- @return true, remaining | false, 0
function _M.take(key)
  local d = dict()
  if not d then
    local n = fallback[key] or 0
    if n > 0 then
      fallback[key] = n - 1
      return true, n - 1
    end
    return false, 0
  end

  -- incr(key, -1, 0)：key 不存在时先置 0 再 -1，返回新值
  local left = d:incr(key, -1, 0)
  if left == nil then
    return false, 0
  end
  if left >= 0 then
    return true, left
  end

  -- 扣成负数说明库存空了，回滚掉这一次
  local v = d:incr(key, 1, 0)
  -- 回滚后若归零，给个短 TTL：避免"从未领到过令牌的 key"永久驻留 shared dict
  if v == 0 then
    d:expire(key, 60)
  end
  return false, 0
end

--- 把从 Redis 领到的一批令牌放进本地库存。
function _M.fill(key, n, ttl_seconds)
  if not n or n <= 0 then
    return
  end

  local d = dict()
  if not d then
    if fallback_keys > FALLBACK_MAX_KEYS then
      fallback = {}
      fallback_keys = 0
    end
    fallback[key] = (fallback[key] or 0) + n
    fallback_keys = fallback_keys + 1
    return
  end

  d:incr(key, n, 0)
  d:expire(key, ttl_seconds)
end

return _M
