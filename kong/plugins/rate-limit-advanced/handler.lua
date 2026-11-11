-- ============================================================
-- rate-limit-advanced / handler.lua
-- access 阶段：判定是否放行。放在 access 意味着超限请求根本不会打到上游。
-- ============================================================
local algorithm = require "kong.plugins.rate-limit-advanced.lib.algorithm"

local _M = {
  -- 高于大部分业务插件，保证限流先于业务逻辑执行（key-auth 是 1250，这里低于它，
  -- 意味着先认证再限流，可以按 consumer 维度计数）
  PRIORITY = 1002,
  VERSION = "0.1.0",
}

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

  -- Redis 不可用时的两条路：放行（可用性优先）或 503（安全优先）
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

  if not conf.hide_client_headers then
    kong.response.set_header("X-RateLimit-Limit", tostring(conf.limit))
    kong.response.set_header("X-RateLimit-Remaining", tostring(decision.remaining))
    kong.response.set_header("X-RateLimit-Reset", tostring(decision.reset))
  end

  if decision.allowed then
    return
  end

  -- 429：把需要的头一次性传给 exit，不依赖之前 set_header 的残留状态
  local retry_after = math.max(1, math.ceil(decision.retry_after or 1))
  local headers = {
    ["Content-Type"] = "application/json; charset=utf-8",
    ["Retry-After"]  = tostring(retry_after),
  }

  if not conf.hide_client_headers then
    headers["X-RateLimit-Limit"]     = tostring(conf.limit)
    headers["X-RateLimit-Remaining"] = "0"
    headers["X-RateLimit-Reset"]     = tostring(decision.reset)
  end

  return kong.response.exit(429, {
    message     = "API rate limit exceeded",
    limit       = conf.limit,
    window      = conf.window,
    retry_after = retry_after,
  }, headers)
end

return _M
