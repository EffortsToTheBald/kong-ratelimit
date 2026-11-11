-- ============================================================
-- rate-limit-advanced / handler.lua
-- access 阶段：判定是否放行。放在 access 意味着超限请求根本不会打到上游。
-- ============================================================
local algorithm = require "kong.plugins.rate-limit-advanced.lib.algorithm"
local store = require "kong.plugins.rate-limit-advanced.lib.store"

local _M = {
  -- 高于大部分业务插件，保证限流先于业务逻辑执行（key-auth 是 1250，这里低于它，
  -- 意味着先认证再限流，可以按 consumer 维度计数）
  PRIORITY = 1002,
  VERSION = "0.1.0",
}

-- D5：启动自检——shared dict 缺失时本地库存会静默降级为 worker 私有表，
-- 精度下降但功能不中断。必须在启动期把这件事喊出来（P1-8）。
function _M:init_worker()
  local backend = store.backend()
  if backend ~= "shared_dict" then
    kong.log.warn("rate-limit-advanced: lua_shared_dict kong_rl 不可用，本地库存降级为 ",
                  backend, "（每 worker 独立库存，精度下降）")
  end
end

function _M:access(conf)
  local key, kerr = algorithm.build_key(conf)
  if not key then
    kong.log.err("rate-limit-advanced: bad config: ", kerr)
    return kong.response.exit(500, {
      message = "rate-limit-advanced: misconfigured",
      detail  = kerr,
    })
  end

  local decision, derr = algorithm.check(conf, key)

  -- Redis 不可用时的两条路：放行（显式容错）或 503（默认 fail-closed）
  if not decision then
    if conf.fault_tolerant then
      kong.log.warn("rate-limit-advanced: limiter unavailable, failing open: ", derr)
      kong.response.set_header("X-RateLimit-Status", "degraded")
      return
    end

    kong.log.err("rate-limit-advanced: limiter unavailable, failing closed: ", derr)
    return kong.response.exit(503, {
      message = "rate limiter unavailable",
    })
  end

  if not decision.allowed then
    -- 429：确定性限流拒绝，打判定日志（notice 级在 KONG_LOG_LEVEL=notice 下可见），
    -- 使"确定性拒绝"可与 Redis 故障（fail 分支日志）区分。
    kong.log.notice("rate-limit-advanced: 429 key=", key,
                    " limit=", conf.limit, " batch=", algorithm.resolve_batch(conf))

    -- D2：Retry-After 封顶为 window（一个窗口内必补 >= 1 个令牌）
    local retry_after = math.max(1, math.ceil(decision.retry_after or 1))
    local window_cap = math.floor(conf.window)
    if window_cap < 1 then
      window_cap = 1
    end
    if retry_after > window_cap then
      retry_after = window_cap
    end

    -- D1：Reset 与 Retry-After 同口径 —— 下一令牌可用的 Unix 秒
    local reset = math.floor(ngx.now() + retry_after)

    -- 429：把需要的头一次性传给 exit，不依赖之前 set_header 的残留状态
    local headers = {
      ["Content-Type"] = "application/json; charset=utf-8",
      ["Retry-After"]  = tostring(retry_after),
    }
    if not conf.hide_client_headers then
      headers["X-RateLimit-Limit"]     = tostring(conf.limit)
      headers["X-RateLimit-Remaining"] = "0"
      headers["X-RateLimit-Reset"]     = tostring(reset)
    end

    return kong.response.exit(429, {
      message     = "API rate limit exceeded",
      limit       = conf.limit,
      window      = conf.window,
      retry_after = retry_after,
    }, headers)
  end

  if not conf.hide_client_headers then
    kong.response.set_header("X-RateLimit-Limit", tostring(conf.limit))
    kong.response.set_header("X-RateLimit-Remaining", tostring(decision.remaining))
    kong.response.set_header("X-RateLimit-Reset", tostring(decision.reset))
  end

  return
end

return _M
