-- ============================================================
-- rate-limit-advanced / handler.lua
-- access 阶段：判定是否放行。放在 access 意味着超限请求根本不会打到上游。
-- ============================================================
local algorithm = require "kong.plugins.rate-limit-advanced.lib.algorithm"

local _M = {
  -- 高于大部分业务插件，保证限流先于业务逻辑执行（key-auth 是 1250，这里低于它，
  -- 意味着先认证再限流，可以按 consumer 维度计数）
  PRIORITY = 1002,
  VERSION = "0.2.0",
}

-- V1 Lease 模型（Phase 6）：库存 = Worker 私有 Lua table（lease.lua），
-- 不依赖 shared dict；本地 TAKE 零 IO，Redis 故障语义只由 GRANT 路径决定
-- （Fail-close/Fail-open 分支保持 batch=1 时代原样，见 access 内 nil-decision 分支）。
-- Legacy shared-dict 聚合库存（store.lua）已随 Phase 8 批次 A 移除。
function _M:init_worker()
  kong.log.notice("rate-limit-advanced: V1 lease mode (worker-private table, no shared dict)")
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

  -- D5：多规则模式的 limit 口径 = 瓶颈/拒绝规则的 limit（单规则路径保持 conf.limit）
  local shown_limit = decision.multi_limit or conf.limit

  if not decision.allowed then
    -- 429：确定性限流拒绝，打判定日志（notice 级在 KONG_LOG_LEVEL=notice 下可见），
    -- 使"确定性拒绝"可与 Redis 故障（fail 分支日志）区分。
    kong.log.notice("rate-limit-advanced: 429 key=", key,
                    " limit=", shown_limit,
                    " batch=", algorithm.resolve_batch(conf),
                    decision.reject_rules and (" reject=" .. decision.reject_rules) or "")

    -- D2：Retry-After 封顶（单规则 = window；多规则 = 不足规则 window 最大值，同口径）
    local retry_after = math.max(1, math.ceil(decision.retry_after or 1))
    local window_cap = decision.reject_cap or math.floor(conf.window)
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
      headers["X-RateLimit-Limit"]     = tostring(shown_limit)
      headers["X-RateLimit-Remaining"] = "0"
      headers["X-RateLimit-Reset"]     = tostring(reset)
    end

    -- D5：多规则模式下响应体 rule 字段标明拒绝来源（人读标识，非内部裸序号）
    local body = {
      message     = "API rate limit exceeded",
      limit       = shown_limit,
      window      = decision.reject_cap and conf.rules[decision.reject_primary].window or conf.window,
      retry_after = retry_after,
    }
    if decision.reject_rules then
      body.rule = decision.reject_rules
    end

    return kong.response.exit(429, body, headers)
  end

  if not conf.hide_client_headers then
    kong.response.set_header("X-RateLimit-Limit", tostring(shown_limit))
    kong.response.set_header("X-RateLimit-Remaining", tostring(decision.remaining))
    kong.response.set_header("X-RateLimit-Reset", tostring(decision.reset))
  end

  return
end

return _M
