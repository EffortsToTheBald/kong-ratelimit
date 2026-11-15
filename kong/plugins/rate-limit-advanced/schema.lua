-- ============================================================
-- rate-limit-advanced / schema.lua
-- Configuration model. Kong uses it for: Admin API input validation, declarative config validation,
-- and generating the Admin API /schemas/plugins/rate-limit-advanced docs.
-- ============================================================
local typedefs = require "kong.db.schema.typedefs"

local DIMENSIONS = {
  "consumer", "ip", "path", "method", "header", "route", "service",
}

-- D2: default value of limit_by (["ip"]). The rules mutual-exclusion check uses the approximate semantics of "≠ default → reject" —
-- after projection, "explicitly set to ["ip"]" cannot be distinguished from "not set"; docs note that limit_by is ignored in rules mode.
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

-- D2 mutual exclusion: non-empty rules ⇒ limit_by must not be explicitly set (reject if ≠ ["ip"]).
-- Note: during init (declarative config loading) the entity field may be a userdata proxy, not a plain validation-time table —
-- only judge true tables; pass through other shapes (real validation happens in Admin API / kong validate).
-- The same fn also covers the remaining rules preconditions (batch∈{0,1}, per-rule header_name);
-- all of these rely on the "rules is a plain table" premise, merged into a single pass.
local function check_rules_config(entity)
  local cfg = entity.config
  local rules = cfg and cfg.rules
  if type(rules) ~= "table" or #rules == 0 then
    return true
  end

  -- Mutual exclusion: non-empty rules ⇒ limit_by not set (reject if ≠ default, D2 approximate semantics)
  local limit_by = cfg.limit_by
  if not same_array(limit_by or {}, DEFAULT_LIMIT_BY) then
    return nil, "config.limit_by and config.rules are mutually exclusive: limit_by must not be set in rules mode (omit it)"
  end

  -- α: non-empty rules ⇒ batch must be ∈ {0,1} (no lease semantics; batch>1 fails fast)
  local batch = cfg.batch or 0
  if batch > 1 then
    return nil, "config.batch: batch must be 0 or 1 in rules mode (strict-consistency mode has no local lease)"
  end

  -- Per rule: limit_by contains "header" ⇒ header_name is required (same semantics as the top-level conditional)
  for i = 1, #rules do
    local rule = rules[i]
    local dims = rule and rule.limit_by
    if type(dims) == "table" then
      for j = 1, #dims do
        if dims[j] == "header"
           and (rule.header_name == nil or rule.header_name == "") then
          return nil, "config.rules[" .. i .. "].header_name: required field missing"
              .. " (rules whose limit_by contains header must declare header_name)"
        end
      end
    end
  end

  return true
end

return {
  name = "rate-limit-advanced",
  -- P1-4: config pre-validation (design D4; verified Kong 3.6 supports entity_checks + conditional + contains)
  -- limit_by contains "header" ⇒ header_name required; bad configs are rejected with 400 at Admin API submission time.
  entity_checks = {
    { conditional = {
        if_field = "config.limit_by",
        if_match = { contains = "header" },
        then_field = "config.header_name",
        then_match = { required = true },
    } },
    { custom_entity_check = {
        field_sources = { "config.rules", "config.limit_by", "config.batch" },
        fn = check_rules_config,
    } },
  },
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- Number of requests allowed per window seconds
          { limit = { type = "integer", required = true, gt = 0 } },
          -- Window length (seconds). rate = limit / window
          { window = { type = "number", default = 60, gt = 0 } },
          -- Bucket capacity. 0 = follow limit (allows the full burst within one window)
          { burst = { type = "integer", default = 0, between = { 0, 100000000 } } },
          -- Number of tokens fetched from Redis per call. 0 = auto (clamp(limit/50, 1, 50))
          -- 1 = strictly globally consistent (1 RTT per request)
          { batch = { type = "integer", default = 0, between = { 0, 100000000 } } },
          -- Rate limiting dimensions, combinable. key = namespace + each dimension value
          {
            limit_by = {
              type = "array",
              default = { "ip" },
              len_min = 1,
              elements = { type = "string", one_of = DIMENSIONS },
            },
          },
          -- Required when limit_by contains "header"
          { header_name = { type = "string" } },
          -- D1/D2: multi-rule joint decision (α strict-consistency mode). Mutually exclusive with limit_by (see entity_checks).
          -- Each rule has independent limiting params; all rule buckets are decided all-or-nothing atomically.
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
          -- Do not send X-RateLimit-* headers (for gateway-internal limiting)
          { hide_client_headers = { type = "boolean", default = false } },
          -- On Redis failure: false (default) = Fail-Closed with 503; true = explicitly allow and mark degraded
          { fault_tolerant = { type = "boolean", default = false } },
          {
            redis = {
              type = "record",
              fields = {
                { host = { type = "string", default = "127.0.0.1" } },
                { port = { type = "integer", default = 6379, between = { 1, 65535 } } },
                -- Gate 6: aligned with the official Kong 3.6 redis schema (kong.tools.redis.schema) —
                -- password supports secrets management ({vault://...} references, referenceable) and encryption at rest
                -- (encrypted; DB-less has no storage, does not affect this repo's operation)
                { password = { type = "string", encrypted = true, referenceable = true, len_min = 0 } },
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
