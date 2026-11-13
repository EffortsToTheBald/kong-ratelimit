-- 独立的 Lease 授予脚本（GRANT_LEASE），用于 redis-cli 裸跑验证。
-- 与 kong/plugins/rate-limit-advanced/lib/redis.lua 内嵌 GRANT_LEASE 双源同步（diff 校验）。
--
-- 一次调用原子完成：参数校验 → 桶 refill → 部分授予判定 → 扣桶 → 创建 Lease 记录（OPEN）→ 设置 TTL。
-- 禁止拆成"先扣桶、客户端再建记录"（两次操作间故障无法确定额度归属）。
-- Redis Lua 运行时错误不回滚已执行写：所有校验前置到任何写之前。
--
-- refill 持久化语义（与 TOKEN_BUCKET 统一，审查 P1-1 裁决）：
--   elapsed = max(0, now - ts)；tokens = min(capacity, old_tokens + rate*elapsed)；
--   ts 只前进不后退；**granted<1 的不足分支同样写回 refill 后的 tokens/ts 并更新桶 TTL**
--   （GRANT_MULTI 的"不足不写"是多键全或无语义所需，单键脚本不适用）。
-- wait 返回语义（审查 P1-3 裁决）：与 TOKEN_BUCKET 契约一致——
--   距下一个令牌可用的秒数，按**扣减后** tokens 计算（部分授予时 wait>0）。
-- 桶状态数值合法性（审查 P1-2 裁决）：tokens ∈ [0, capacity]、ts ≥ 0、有限数值；
--   非法状态返回明确错误码，**不得静默修正**，数据保持不变。
--
-- 用法：
--   redis-cli --eval redis/grant_lease.lua <桶键> , <lease键> , batch lease_ttl_ms lease_id pool_key rate capacity bucket_ttl_ms
--   KEYS[1] = 桶键（tokens/ts）
--   KEYS[2] = kong:rl:lease:{lease_id}（{...} 为占位符语法，实际 Key 无大括号）
--   ARGV[1] = batch（本批授予上限，正整数）
--   ARGV[2] = lease_ttl_ms（Lease 记录 TTL：max_lifetime + 3×redis_timeout + 60s，调用方计算）
--   ARGV[3] = lease_id（全局唯一）
--   ARGV[4] = pool_key（限流桶键/策略版本，RETURN 时校验）
--   ARGV[5] = rate（每秒补充，与其他脚本统一来源）
--   ARGV[6] = capacity（桶容量，与其他脚本统一来源）
--   ARGV[7] = bucket_ttl_ms（桶 TTL：2×window，与 TOKEN_BUCKET 一致）
--
-- 返回：
--   成功（granted>0）：{ granted, tokens(字符串), wait(字符串) }，并创建 status=OPEN 的 Lease
--   不足（refill 后 tokens<1）：{ 0, tokens(字符串), wait(字符串) }，不创建 Lease；
--     但**写回 refill 后的桶状态与 TTL**（与 TOKEN_BUCKET 一致）
--   失败：错误码（LEASE_EXISTS / INVALID_ARGUMENT，零写入）
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

-- 阶段 0：参数校验（零写入）
if not batch or batch ~= math.floor(batch) or batch < 1 or batch >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT batch')
end
if not lease_ttl_ms or lease_ttl_ms ~= math.floor(lease_ttl_ms) or lease_ttl_ms < 1 then
  return redis.error_reply('INVALID_ARGUMENT lease_ttl_ms')
end
if not lease_id or lease_id == '' or not pool_key or pool_key == '' then
  return redis.error_reply('INVALID_ARGUMENT lease_id/pool_key')
end
if not is_finite_num(rate) or rate <= 0
   or not is_finite_num(capacity) or capacity <= 0 or capacity >= 2^53 then
  return redis.error_reply('INVALID_ARGUMENT rate/capacity')
end
if not bucket_ttl_ms or bucket_ttl_ms ~= math.floor(bucket_ttl_ms) or bucket_ttl_ms < 1 then
  return redis.error_reply('INVALID_ARGUMENT bucket_ttl_ms')
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
-- wait 返回契约（与 TOKEN_BUCKET 一致）：按扣减后 tokens 计算
local wait = 0
if rate > 0 then
  wait = math.max(0, (1 - tokens) / rate)
end

-- 桶状态写回：授予与不足分支统一（与 TOKEN_BUCKET 一致，审查 P1-1 裁决）
tokens = tokens - granted
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
