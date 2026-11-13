-- ============================================================
-- rate-limit-advanced / lib/redis.lua
-- Redis 连接（keepalive 复用）+ 内嵌令牌桶脚本。
--
-- 为什么要内嵌脚本而不是读文件：
--   1) 插件目录只读挂载，避免运行期 IO
--   2) EVAL 的脚本文本会被 Redis 按 SHA 缓存，反复调用不会重复解析
-- ============================================================
local redis = require "resty.redis"

local _M = {}

-- ------------------------------------------------------------
-- 令牌桶（服务端时间）
--
-- KEYS[1] bucket key
-- ARGV[1] rate   每秒补充的令牌数
-- ARGV[2] burst  桶容量
-- ARGV[3] want   本次想领几个
-- ARGV[4] ttl    过期时间（毫秒）
--
-- 返回 { granted(整数), tokens(字符串), wait(字符串) }
--
-- 注意：
--   * TIME 取 Redis 自己的时钟，消除多网关节点的时钟漂移
--   * 浮点必须 tostring 返回，否则 Redis 会把 number 截断成整数
-- ------------------------------------------------------------
local TOKEN_BUCKET = [[
local key   = KEYS[1]
local rate  = tonumber(ARGV[1])
local burst = tonumber(ARGV[2])
local want  = tonumber(ARGV[3])
local ttl   = tonumber(ARGV[4])

local t   = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000

local d      = redis.call('HMGET', key, 'tokens', 'ts')
local tokens = tonumber(d[1])
local ts     = tonumber(d[2])

if tokens == nil then tokens = burst end
if ts == nil then ts = now end

-- P0-4：ts 只前进不后退。时钟回拨期间不补充、也不把 ts 改小，
-- 否则时钟追上后，同一段时间会被二次计费，凭空多出令牌。
if now > ts then
  tokens = tokens + (now - ts) * rate
  if tokens > burst then tokens = burst end
  ts = now
end

local granted = 0
if tokens >= want then
  granted = want
elseif tokens >= 1 then
  granted = math.floor(tokens)
end

tokens = tokens - granted

-- D1：wait 统一为"距下一个令牌可用的秒数"。
-- tokens >= 1 时 (1-tokens) <= 0，钳到 0（下一令牌已可用）；
-- tokens < 1 时为补足一个整令牌所需等待。
local wait = 0
if rate > 0 then
  wait = (1 - tokens) / rate
  if wait < 0 then
    wait = 0
  end
end

redis.call('HSET', key, 'tokens', tostring(tokens), 'ts', tostring(ts))
redis.call('PEXPIRE', key, ttl)

return { granted, tostring(tokens), tostring(wait) }
]]

_M.script = TOKEN_BUCKET

-- ------------------------------------------------------------
-- D4：多键原子脚本（α 强一致模式）。与 redis/multi_bucket.lua 双源同步。
--
-- KEYS   = r1..rN 各规则桶键（组内同 hash tag ⇒ 同 slot）
-- ARGV[1]= n，其后每规则 3 个参数：rate burst ttl_ms
-- 返回（扁平数组）：
--   成功 { 1, tokens_1, wait_1, ..., tokens_n, wait_n }（扣减后）
--   失败 { 0, 规则序号, wait, ... }（不足规则，全桶未动）
-- 语义：单脚本内"全检-全扣/全不扣"——检查与扣减不可分割，无本地回滚窗口。
-- ------------------------------------------------------------
local GRANT_MULTI = [[
local n = tonumber(ARGV[1])

local t   = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000

-- 1) 逐桶 refill（与单桶脚本同公式：TIME 单调、burst 封顶、ts 只前进不后退）
local tokens = {}
local ts = {}
local rate = {}
local burst = {}
local ttl = {}
for i = 1, n do
  rate[i]  = tonumber(ARGV[2 + (i - 1) * 3])
  burst[i] = tonumber(ARGV[3 + (i - 1) * 3])
  ttl[i]   = tonumber(ARGV[4 + (i - 1) * 3])

  local d = redis.call('HMGET', KEYS[i], 'tokens', 'ts')
  local tk  = tonumber(d[1])
  local lts = tonumber(d[2])
  if tk == nil then tk = burst[i] end
  if lts == nil then lts = now end

  -- P0-4：ts 只前进不后退。时钟回拨期间不补充、也不把 ts 改小，
  -- 否则时钟追上后，同一段时间会被二次计费，凭空多出令牌。
  if now > lts then
    tk = tk + (now - lts) * rate[i]
    if tk > burst[i] then tk = burst[i] end
    lts = now
  end

  tokens[i] = tk
  ts[i] = lts
end

-- D1 wait 口径：tokens >= 1 时为 0（下一令牌已可用）；< 1 时为补足一个整令牌所需等待。
local function wait_of(i, tk)
  if rate[i] <= 0 then
    return 0
  end
  local w = (1 - tk) / rate[i]
  if w < 0 then
    return 0
  end
  return w
end

-- 2) 全检：所有桶 refill 后 tokens >= 1 才扣
local all_ok = true
for i = 1, n do
  if tokens[i] < 1 then
    all_ok = false
  end
end

if all_ok then
  local out = { 1 }
  for i = 1, n do
    tokens[i] = tokens[i] - 1
    redis.call('HSET', KEYS[i], 'tokens', tostring(tokens[i]), 'ts', tostring(ts[i]))
    redis.call('PEXPIRE', KEYS[i], ttl[i])
    out[#out + 1] = tostring(tokens[i])
    out[#out + 1] = tostring(wait_of(i, tokens[i]))
  end
  return out
end

-- 3) 任一不足 → 全部不写（不扣任何桶、不更新任何 ts），返回不足规则与各自 wait
local out = { 0 }
for i = 1, n do
  if tokens[i] < 1 then
    out[#out + 1] = i
    out[#out + 1] = tostring(wait_of(i, tokens[i]))
  end
end
return out
]]
-- ------------------------------------------------------------
-- GRANT_LEASE（Phase 3）：Lease 授予（桶扣减 + Lease 记录创建原子）。
-- KEYS[1]=桶键 KEYS[2]=kong:rl:lease:{lease_id}
-- ARGV=[batch, lease_ttl_ms, lease_id, pool_key, rate, capacity, bucket_ttl_ms]
-- 返回 {granted, tokens, wait} 或错误码（LEASE_EXISTS/INVALID_ARGUMENT，零写入）。
-- tokens<1 ⇒ granted=0 不建记录。详细语义见 redis/grant_lease.lua（双源）。
-- ------------------------------------------------------------
local GRANT_LEASE = [[
local bkey   = KEYS[1]
local lkey   = KEYS[2]
local batch  = tonumber(ARGV[1])
local lease_ttl_ms = tonumber(ARGV[2])
local lease_id     = ARGV[3]
local pool_key     = ARGV[4]
local rate         = tonumber(ARGV[5])
local capacity     = tonumber(ARGV[6])
local bucket_ttl_ms = tonumber(ARGV[7])

-- 有限数值判定（Lua 无 isfinite：NaN 自不等、±inf 与 huge 比较）
local function is_finite_num(v)
  return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_valid_ttl(v)
  return is_finite_num(v) and v == math.floor(v) and v >= 1 and v < 2^53
end

-- 阶段 0：参数校验（零写入）
if not batch or batch ~= math.floor(batch) or batch < 1 or batch >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT batch')
end
if not is_valid_ttl(lease_ttl_ms) then
  return redis.error_reply('INVALID_ARGUMENT lease_ttl_ms: ' .. tostring(ARGV[2]))
end
if not lease_id or lease_id == '' or not pool_key or pool_key == '' then
  return redis.error_reply('INVALID_ARGUMENT lease_id/pool_key')
end
if not is_finite_num(rate) or rate <= 0
   or not is_finite_num(capacity) or capacity <= 0 or capacity >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT rate/capacity')
end
if not is_valid_ttl(bucket_ttl_ms) then
  return redis.error_reply('INVALID_ARGUMENT bucket_ttl_ms: ' .. tostring(ARGV[7]))
end

-- 阶段 1：只读校验（零写入）——含桶状态数值合法性（P1-2）
if redis.call('EXISTS', lkey) == 1 then
  return redis.error_reply('LEASE_EXISTS ' .. lease_id)
end
local btype = redis.call('TYPE', bkey).ok
local tokens, ts
if btype == 'none' then
  tokens = capacity   -- 新桶满桶（与 TOKEN_BUCKET 一致）
  ts = nil
elseif btype == 'hash' then
  local d = redis.call('HMGET', bkey, 'tokens', 'ts')
  if d[1] ~= false and d[1] ~= nil then
    tokens = tonumber(d[1])
    if not is_finite_num(tokens) or tokens < 0 or tokens > capacity then
      return redis.error_reply('INVALID_ARGUMENT bucket tokens: ' .. tostring(d[1]))
    end
  end
  if d[2] ~= false and d[2] ~= nil then
    ts = tonumber(d[2])
    if not is_finite_num(ts) or ts < 0 then
      return redis.error_reply('INVALID_ARGUMENT bucket ts: ' .. tostring(d[2]))
    end
  end
else
  return redis.error_reply('INVALID_ARGUMENT bucket type: ' .. btype)
end

-- 阶段 2：refill → 授予判定 → 扣桶 → 建 Lease（原子，Redis 串行无穿插）
local t   = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
if tokens == nil then tokens = capacity end
local elapsed = 0
if ts ~= nil and now > ts then
  elapsed = now - ts
end
tokens = math.min(capacity, tokens + elapsed * rate)
if elapsed > 0 then
  ts = now
end
-- P0-4：ts 只前进不后退（now<=ts 时不补充、不改小 ts）

local granted = math.min(batch, math.floor(tokens))
-- 顺序（审查 P1-1）：1) granted 判定 2) 扣减 3) wait 按扣减后 tokens 计算
--   4) 写回 Bucket 5) 返回 granted/tokens/wait
tokens = tokens - granted
local wait = 0
if rate > 0 then
  wait = math.max(0, (1 - tokens) / rate)
end

-- 桶状态写回：授予与不足分支统一（与 TOKEN_BUCKET 一致，审查 P1-1 裁决）
if ts == nil or now > ts then ts = now end
redis.call('HSET', bkey, 'tokens', tostring(tokens), 'ts', tostring(ts))
redis.call('PEXPIRE', bkey, bucket_ttl_ms)

if granted < 1 then
  -- tokens < 1：不创建 Lease（桶状态已写回）
  return { 0, tostring(tokens), tostring(wait) }
end

redis.call('HSET', lkey,
  'lease_id', lease_id,
  'pool_key', pool_key,
  'granted', granted,
  'status', 'OPEN',
  'created_at', tostring(now))
redis.call('PEXPIRE', lkey, lease_ttl_ms)

return { granted, tostring(tokens), tostring(wait) }
]]

-- ------------------------------------------------------------
-- RETURN_LEASE（Phase 3）：Lease 幂等归还（提交点先行）。
-- KEYS[1]=kong:rl:lease:{lease_id} KEYS[2]=桶键
-- ARGV=[requested, pool_key, bucket_ttl_ms, rate, capacity]
-- 写顺序铁律：先写 RETURNED 标记（幂等提交点），后一次 HSET 完整桶状态。
-- 返回 {requested, applied, discarded} 或错误码（均零写入）。
-- 详细语义见 redis/return_lease.lua（双源）。
-- ------------------------------------------------------------
local RETURN_LEASE = [[
local lkey  = KEYS[1]
local bkey  = KEYS[2]
local function is_finite_num(v)
  return v ~= nil and v == v and v ~= math.huge and v ~= -math.huge
end
local function is_valid_ttl(v)
  return is_finite_num(v) and v == math.floor(v) and v >= 1 and v < 2^53
end
local requested = tonumber(ARGV[1])
local pool_key  = ARGV[2]
local bucket_ttl_ms = tonumber(ARGV[3])
local rate      = tonumber(ARGV[4])
local capacity  = tonumber(ARGV[5])

-- 阶段 0：参数校验（零写入）
if not requested or requested ~= math.floor(requested) or requested < 0 or requested >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT requested')
end
if not pool_key or pool_key == '' then
  return redis.error_reply('INVALID_ARGUMENT pool_key')
end
if not is_valid_ttl(bucket_ttl_ms) then
  return redis.error_reply('INVALID_ARGUMENT bucket_ttl_ms: ' .. tostring(ARGV[3]))
end
if not is_finite_num(rate) or rate <= 0
   or not is_finite_num(capacity) or capacity <= 0 or capacity >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT rate/capacity')
end

-- 桶状态数值合法性（审查 P1-2 裁决，与 GRANT_LEASE 一致）：tokens ∈ [0, capacity]、
--   ts ≥ 0、有限数值、granted 正整数 <2^53——非法返回明确错误码，不得静默修正，数据不变。
-- 阶段 1：只读校验（零写入）
if redis.call('EXISTS', lkey) == 0 then
  return redis.error_reply('LEASE_NOT_FOUND')
end
local status = redis.call('HGET', lkey, 'status')
if status == 'RETURNED' then
  local rr = redis.call('HGET', lkey, 'return_requested')
  if tonumber(rr) == requested then
    return redis.error_reply('ALREADY_RETURNED')
  end
  return redis.error_reply('RETURN_CONFLICT requested=' .. tostring(requested) .. ' return_requested=' .. tostring(rr))
end
if status ~= 'OPEN' then
  return redis.error_reply('INVALID_LEASE_STATE ' .. tostring(status))
end
local lpk = redis.call('HGET', lkey, 'pool_key')
if lpk ~= pool_key then
  return redis.error_reply('POOL_MISMATCH')
end
local granted = tonumber(redis.call('HGET', lkey, 'granted'))
if not is_finite_num(granted) or granted ~= math.floor(granted)
   or granted < 1 or granted >= 2^53 then
  return redis.error_reply('INVALID_LEASE_STATE granted: ' .. tostring(redis.call('HGET', lkey, 'granted')))
end
if requested > granted then
  return redis.error_reply('INVALID_REQUESTED requested=' .. tostring(requested) .. ' granted=' .. tostring(granted))
end
local btype = redis.call('TYPE', bkey).ok
if btype == 'none' then
  return redis.error_reply('BUCKET_NOT_FOUND')
end
if btype ~= 'hash' then
  return redis.error_reply('INVALID_ARGUMENT bucket type: ' .. btype)
end
local d = redis.call('HMGET', bkey, 'tokens', 'ts')
local btokens, bts
if d[1] ~= false and d[1] ~= nil then
  btokens = tonumber(d[1])
  if not is_finite_num(btokens) or btokens < 0 or btokens > capacity then
    return redis.error_reply('INVALID_ARGUMENT bucket tokens: ' .. tostring(d[1]))
  end
end
if d[2] ~= false and d[2] ~= nil then
  bts = tonumber(d[2])
  if not is_finite_num(bts) or bts < 0 then
    return redis.error_reply('INVALID_ARGUMENT bucket ts: ' .. tostring(d[2]))
  end
end

-- 阶段 2：写（校验全通过后）
-- 【幂等提交点】先写 RETURNED 标记与 return_requested（此后任何失败 ⇒ 重试得 ALREADY_RETURNED）
redis.call('HSET', lkey, 'status', 'RETURNED', 'return_requested', requested)

local applied = 0
if requested > 0 then
  local t   = redis.call('TIME')
  local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
  local tokens = btokens
  local ts     = bts
  if tokens == nil then tokens = capacity end   -- hash 存在但无字段（与授予侧一致：满桶）
  if ts ~= nil and now > ts then
    tokens = math.min(capacity, tokens + (now - ts) * rate)
    ts = now
  end
  local refilled = tokens
  local new_tokens = math.min(capacity, refilled + requested)
  applied = new_tokens - refilled
  if ts == nil or now > ts then ts = now end
  redis.call('HSET', bkey, 'tokens', tostring(new_tokens), 'ts', tostring(ts))
  redis.call('PEXPIRE', bkey, bucket_ttl_ms)
end
-- requested=0：跳过桶更新，仍完成 OPEN→RETURNED（账目闭合）

-- Lease 记录 TTL 不重设（RETURNED 保留至原 TTL = 幂等保护窗口）
return { requested, applied, requested - applied }
]]

_M.multi_script = GRANT_MULTI

-- ------------------------------------------------------------
-- EVALSHA 统一管理（Phase 2）：
--   * 脚本表持有 src 与 SHA；SHA 以 SCRIPT LOAD 返回值为准，Worker 级缓存
--     （OpenResty 每个 Worker 独立 Lua VM，模块状态天然按 Worker 隔离）。
--   * Redis 脚本缓存是**实例级**（单实例部署前提下，任一连接 LOAD 后
--     该实例上所有连接的 EVALSHA 均可用；Cluster 的按节点缓存为 Deferred）。
--   * init_worker 不做任何 Redis IO：懒加载（首次调用触发 LOAD）。
--   * 仅"明确 NOSCRIPT"触发 LOAD + 重试恰一次；超时/连接断开/普通错误
--     一律原样透传，绝不当作 NOSCRIPT（防止重复执行已成功的扣减）。
-- ------------------------------------------------------------
local SCRIPTS = {}

local function register_script(name, src)
    SCRIPTS[name] = { name = name, src = src, sha = nil }
end
register_script("token_bucket", TOKEN_BUCKET)
register_script("grant_multi", GRANT_MULTI)
register_script("grant_lease", GRANT_LEASE)
register_script("return_lease", RETURN_LEASE)
_M.scripts = SCRIPTS

local function is_noscript_err(err)
    return type(err) == "string" and string.find(err, "NOSCRIPT", 1, true) ~= nil
end

local function load_script(r, entry)
    local sha, err = r:script("LOAD", entry.src)
    if not sha or sha == ngx.null then
        return nil, "script load failed: " .. tostring(err)
    end
    entry.sha = sha
    -- NOSCRIPT 仅在脚本缓存丢失（FLUSH/重启）后出现，频率极低，warn 便于审计
    if kong and kong.log then
        kong.log.warn("rate-limit-advanced: script cache miss (NOSCRIPT), loaded: ", entry.name)
    end
    return sha
end

--- EVALSHA 包装：懒加载 + NOSCRIPT 重载重试恰一次。
-- @return res, err —— err 为明确错误时调用方走既有故障分支
local function evalsha(r, entry, ...)
    if not entry.sha then
        local sha, lerr = load_script(r, entry)
        if not sha then
            return nil, lerr
        end
    end
    local res, err = r:evalsha(entry.sha, ...)
    if not res and is_noscript_err(err) then
        local sha, lerr = load_script(r, entry)
        if not sha then
            return nil, lerr
        end
        res, err = r:evalsha(entry.sha, ...)
        if not res and is_noscript_err(err) then
            return nil, "script still missing after reload: " .. tostring(err)
        end
    end
    return res, err
end
_M.load_script = load_script
_M.evalsha = evalsha

--- D3：防御性校验 EVAL 返回值（纯函数，不依赖 cosocket，可被 resty 单测直接调用）。
-- 合法形态：{ granted(整数, 0..want), tokens(数值), wait(数值, >=0) }。
-- 任一不满足 → nil, 原因；调用方（grant）将其视为 Redis 异常并进入故障分支。
-- @return table|nil, string|nil
local function parse_grant_response(res, want)
  if type(res) ~= "table" or #res ~= 3 then
    return nil, "malformed eval response: expected 3-element array"
  end

  local granted = tonumber(res[1])
  if granted == nil
     or granted ~= math.floor(granted)
     or granted < 0
     or granted > want then
    return nil, "malformed eval response: granted out of range"
  end

  local tokens = tonumber(res[2])
  if tokens == nil then
    return nil, "malformed eval response: tokens not a number"
  end

  local wait = tonumber(res[3])
  if wait == nil or wait < 0 then
    return nil, "malformed eval response: wait not a number"
  end

  return {
    granted = granted,
    tokens  = tokens,
    wait    = wait,
  }
end
_M.parse_grant_response = parse_grant_response

--- D4：多键脚本返回值的防御校验（纯函数，不依赖 cosocket，可被 resty 单测直接调用）。
-- 合法形态：
--   ok=1：{ 1, tokens_1, wait_1, ..., tokens_n, wait_n }（tokens>=0 数值、wait>=0 数值）
--   ok=0：{ 0, idx, wait, ... }（idx 为 1..n 内的整数且不重复，wait>=0 数值，至少 1 对）
-- 任一不满足 → nil, 原因；调用方（grant_multi）将其视为 Redis 异常并进故障分支。
-- @return table|nil, string|nil
local function parse_multi_grant_response(n, res)
  if type(res) ~= "table" or #res < 1 then
    return nil, "malformed multi eval response: expected non-empty array"
  end

  local ok = tonumber(res[1])

  if ok == 1 then
    if #res ~= 1 + 2 * n then
      return nil, "malformed multi eval response: expected 1+2n elements for ok=1"
    end
    local buckets = {}
    for i = 1, n do
      local tokens = tonumber(res[2 * i])
      local wait   = tonumber(res[2 * i + 1])
      if tokens == nil or tokens < 0 then
        return nil, "malformed multi eval response: tokens out of range (rule " .. i .. ")"
      end
      if wait == nil or wait < 0 then
        return nil, "malformed multi eval response: wait out of range (rule " .. i .. ")"
      end
      buckets[i] = { tokens = tokens, wait = wait }
    end
    return { ok = 1, buckets = buckets }
  end

  if ok == 0 then
    local rest = #res - 1
    if rest == 0 or rest % 2 ~= 0 then
      return nil, "malformed multi eval response: expected idx/wait pairs for ok=0"
    end
    local rejects = {}
    local seen = {}
    local k = 0
    for p = 2, #res, 2 do
      local idx  = tonumber(res[p])
      local wait = tonumber(res[p + 1])
      if idx == nil or idx ~= math.floor(idx) or idx < 1 or idx > n or seen[idx] then
        return nil, "malformed multi eval response: reject rule index out of range"
      end
      if wait == nil or wait < 0 then
        return nil, "malformed multi eval response: reject wait out of range"
      end
      seen[idx] = true
      k = k + 1
      rejects[k] = { rule = idx, wait = wait }
    end
    return { ok = 0, rejects = rejects }
  end

  return nil, "malformed multi eval response: ok flag not 0/1"
end
_M.parse_multi_grant_response = parse_multi_grant_response

--- 与 grant() 相同的连接建立（为保持单规则路径一行不动，不抽取公共函数）。
-- @return r|nil, err|nil（失败时调用方直接返回）
local function connect(conf)
  local r, nerr = redis:new()
  if not r then
    return nil, "cannot create redis client: " .. tostring(nerr)
  end

  local timeout = conf.redis.timeout or 1000
  if r.set_timeouts then
    r:set_timeouts(timeout, timeout, timeout)
  else
    r:set_timeout(timeout)
  end

  local ok, err = r:connect(conf.redis.host, conf.redis.port)
  if not ok then
    return nil, "connect: " .. tostring(err)
  end

  if conf.redis.password and conf.redis.password ~= "" then
    local aok, aerr = r:auth(conf.redis.password)
    if not aok then
      r:close()
      return nil, "auth: " .. tostring(aerr)
    end
  end

  if conf.redis.database and conf.redis.database > 0 then
    local sok, serr = r:select(conf.redis.database)
    if not sok then
      r:close()
      return nil, "select: " .. tostring(serr)
    end
  end

  return r
end

--- 领取 want 个令牌。
-- rate/burst 由调用方从 limit/window 推导后传入，保持本模块只负责 IO。
-- @return table {granted, tokens, wait} 或 nil, err
function _M.grant(conf, key, want, ttl_ms, rate, burst)
  local r, nerr = redis:new()
  if not r then
    return nil, "cannot create redis client: " .. tostring(nerr)
  end

  local timeout = conf.redis.timeout or 1000
  if r.set_timeouts then
    r:set_timeouts(timeout, timeout, timeout)
  else
    r:set_timeout(timeout)
  end

  local ok, err = r:connect(conf.redis.host, conf.redis.port)
  if not ok then
    return nil, "connect: " .. tostring(err)
  end

  if conf.redis.password and conf.redis.password ~= "" then
    local aok, aerr = r:auth(conf.redis.password)
    if not aok then
      r:close()
      return nil, "auth: " .. tostring(aerr)
    end
  end

  if conf.redis.database and conf.redis.database > 0 then
    local sok, serr = r:select(conf.redis.database)
    if not sok then
      r:close()
      return nil, "select: " .. tostring(serr)
    end
  end

  local res, eerr = evalsha(r, SCRIPTS.token_bucket, 1, key,
                            tostring(rate),
                            tostring(burst),
                            tostring(want),
                            tostring(ttl_ms))
  if not res then
    r:close()
    return nil, "eval: " .. tostring(eerr)
  end

  -- D3：畸形返回按 Redis 异常处理（close 而非 keepalive，进故障分支）
  local parsed, perr = parse_grant_response(res, want)
  if not parsed then
    r:close()
    return nil, perr
  end

  -- 放回连接池：不 keepalive 的话，高并发下会迅速耗尽本地端口
  r:set_keepalive(10000, 100)

  return parsed
end

--- D1/D4：多规则 α 模式的多键原子授予（每桶各扣 1，全或无）。
-- keys[i] 与 rates[i]/bursts[i]/ttls_ms[i] 一一对应（调用方由 rules 推导）。
-- @return {ok=1, buckets={{tokens,wait}…}} 或 {ok=0, rejects={{rule,wait}…}}
--         或 nil, err（连接/脚本/畸形返回 → 调用方走故障分支）
function _M.grant_multi(conf, keys, rates, bursts, ttls_ms)
  local n = #keys
  local argv = { tostring(n) }
  for i = 1, n do
    argv[#argv + 1] = tostring(rates[i])
    argv[#argv + 1] = tostring(bursts[i])
    argv[#argv + 1] = tostring(ttls_ms[i])
  end

  local r, cerr = connect(conf)
  if not r then
    return nil, cerr
  end

  -- eval 参数必须显式拼平：unpack 处在参数列表中间会被 Lua 截成 1 个值
  -- （KEYS 会丢、numkeys 错位），只有末尾的 unpack 才完整展开。
  local args = { n }
  for i = 1, n do
    args[#args + 1] = keys[i]
  end
  for i = 1, #argv do
    args[#args + 1] = argv[i]
  end

  local res, eerr = evalsha(r, SCRIPTS.grant_multi, unpack(args))
  if not res then
    r:close()
    return nil, "eval: " .. tostring(eerr)
  end

  -- D3 同手法：畸形返回按 Redis 异常处理（close 而非 keepalive，进故障分支）
  local parsed, perr = parse_multi_grant_response(n, res)
  if not parsed then
    r:close()
    return nil, perr
  end

  r:set_keepalive(10000, 100)

  return parsed
end

return _M
