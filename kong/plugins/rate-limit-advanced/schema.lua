-- ============================================================
-- rate-limit-advanced / schema.lua
-- 配置模型。Kong 用它做：Admin API 入参校验、声明式配置校验、
-- 以及生成 Admin API 的 /schemas/plugins/rate-limit-advanced 文档。
-- ============================================================
local typedefs = require "kong.db.schema.typedefs"

local DIMENSIONS = {
  "consumer", "ip", "path", "method", "header", "route", "service",
}

return {
  name = "rate-limit-advanced",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- 每 window 秒允许的请求数
          { limit = { type = "integer", required = true, gt = 0 } },
          -- 窗口长度（秒）。rate = limit / window
          { window = { type = "number", default = 60, gt = 0 } },
          -- 桶容量。0 = 跟随 limit（允许一个窗口内的完整突发）
          { burst = { type = "integer", default = 0, between = { 0, 100000000 } } },
          -- 每次向 Redis 领取的令牌数。0 = auto（clamp(limit/50, 1, 50)）
          -- 1 = 严格全局一致（每请求 1 次 RTT）
          { batch = { type = "integer", default = 0, between = { 0, 100000000 } } },
          -- 限流维度，可组合。key = namespace + 各维度值
          {
            limit_by = {
              type = "array",
              default = { "ip" },
              len_min = 1,
              elements = { type = "string", one_of = DIMENSIONS },
            },
          },
          -- limit_by 含 "header" 时必填
          { header_name = { type = "string" } },
          { namespace = { type = "string", default = "rl" } },
          -- 不回 X-RateLimit-* 头（网关内部限流时用）
          { hide_client_headers = { type = "boolean", default = false } },
          -- Redis 故障时：false（默认）= Fail-Closed 返回 503；true = 显式选择放行并标记 degraded
          { fault_tolerant = { type = "boolean", default = false } },
          {
            redis = {
              type = "record",
              fields = {
                { host = { type = "string", default = "127.0.0.1" } },
                { port = { type = "integer", default = 6379, between = { 1, 65535 } } },
                { password = { type = "string" } },
                { database = { type = "integer", default = 0, between = { 0, 15 } } },
                { timeout = { type = "integer", default = 1000, between = { 1, 60000 } } },
                { key_prefix = { type = "string", default = "kong:rl" } },
              },
            },
          },
        },
      },
    },
  },
}
