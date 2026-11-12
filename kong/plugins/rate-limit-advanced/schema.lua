-- ============================================================
-- rate-limit-advanced / schema.lua
-- 配置模型。Kong 用它做：Admin API 入参校验、声明式配置校验、
-- 以及生成 Admin API 的 /schemas/plugins/rate-limit-advanced 文档。
-- ============================================================
local typedefs = require "kong.db.schema.typedefs"

local DIMENSIONS = {
  "consumer", "ip", "path", "method", "header", "route", "service",
}

-- D2：limit_by 的默认值（["ip"]）。rules 互斥校验用"≠默认值 → 拒绝"的近似语义——
-- 投影后无法区分"显式设置 ["ip"]"与"未设置"，文档注明 rules 模式下 limit_by 无效。
local DEFAULT_LIMIT_BY = { "ip" }

local function same_array(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- D2 互斥：rules 非空 ⇒ limit_by 不得显式设置（≠ ["ip"] 即拒）。
-- 注意：init 期（声明式配置加载）entity 字段可能是 userdata 代理，非校验期纯 table——
-- 只对真正的 table 做判定，其余形态放行（真正校验发生在 Admin API / kong validate）。
local function check_rules_exclusivity(entity)
  local rules = entity.config and entity.config.rules
  if type(rules) ~= "table" or #rules == 0 then
    return true
  end
  local limit_by = entity.config.limit_by
  if not same_array(limit_by or {}, DEFAULT_LIMIT_BY) then
    return nil, "config.limit_by 与 config.rules 互斥：rules 模式下不得设置 limit_by（省略即可）"
  end
  return true
end

return {
  name = "rate-limit-advanced",
  -- P1-4：配置前置校验（设计 D4，已核实 Kong 3.6 支持 entity_checks + conditional + contains）
  -- limit_by 含 "header" ⇒ header_name 必填；坏配置在 Admin API 下发时即被 400 拒绝。
  entity_checks = {
    { conditional = {
        if_field = "config.limit_by",
        if_match = { contains = "header" },
        then_field = "config.header_name",
        then_match = { required = true },
    } },
    { custom_entity_check = {
        field_sources = { "config.rules", "config.limit_by" },
        fn = check_rules_exclusivity,
    } },
  },
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
          -- D1/D2：多规则联合判定（α 强一致模式）。与 limit_by 互斥（见 entity_checks）。
          -- 每条规则独立限流参数；全部规则桶全或无原子判定。
          {
            rules = {
              type = "array",
              len_max = 8,
              elements = {
                type = "record",
                fields = {
                  { limit = { type = "integer", required = true, gt = 0 } },
                  { window = { type = "number", default = 60, gt = 0 } },
                  { burst = { type = "integer", default = 0, between = { 0, 100000000 } } },
                  { limit_by = {
                      type = "array",
                      default = { "consumer" },
                      len_min = 1,
                      elements = { type = "string", one_of = DIMENSIONS },
                  } },
                  { header_name = { type = "string" } },
                },
              },
            },
          },
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
