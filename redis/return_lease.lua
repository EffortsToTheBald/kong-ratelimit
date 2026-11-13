-- 独立的 Lease 归还脚本（RETURN_LEASE），用于 redis-cli 裸跑验证。
-- 与 kong/plugins/rate-limit-advanced/lib/redis.lua 内嵌 RETURN_LEASE 双源同步（diff 校验）。
--
-- 一次调用原子完成：参数校验 → 只读校验 → **RETURNED 幂等提交点** → 桶更新。
-- 写顺序铁律：先标记 RETURNED（幂等提交点），后更新 Bucket——
--   Redis Lua 运行时错误不回滚：若"先加桶后标记"，中断 + 重试会重复加桶（超发）；
--   先标记后，中断 ⇒ 重试得 ALREADY_RETURNED 不再加桶（允许损失）。
--
-- 用法：
--   redis-cli --eval redis/return_lease.lua <lease键> , <桶键> , requested pool_key bucket_ttl_ms rate capacity
--   KEYS[1] = kong:rl:lease:{lease_id}
--   KEYS[2] = 桶键
--   ARGV[1] = requested（Lease 关闭时本地 remaining 快照，非负整数 <2^53）
--   ARGV[2] = pool_key（与 Lease 记录校验一致）
--   ARGV[3] = bucket_ttl_ms（桶 TTL：2×window，与授予侧一致）
--   ARGV[4] = rate
--   ARGV[5] = capacity
--
-- 返回：
--   成功：{ requested, applied, discarded }（requested=0 仍完成 OPEN→RETURNED，applied=discarded=0）
--   幂等/错误：错误码——ALREADY_RETURNED / RETURN_CONFLICT / LEASE_NOT_FOUND /
--              INVALID_LEASE_STATE / POOL_MISMATCH / INVALID_REQUESTED /
--              BUCKET_NOT_FOUND / INVALID_ARGUMENT（均零写入）
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
