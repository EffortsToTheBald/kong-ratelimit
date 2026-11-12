-- 独立的多键原子脚本（D4），用于在 redis-cli 裸跑验证"全或无"语义。
-- 与 kong/plugins/rate-limit-advanced/lib/redis.lua 内嵌 GRANT_MULTI 双源同步（diff 校验）。
-- 用法：
--   redis-cli --eval redis/multi_bucket.lua k1 , k2 , 2 , r1_rate r1_burst r1_ttl r2_rate r2_burst r2_ttl
--   KEYS   = 各规则桶键（组内同 hash tag ⇒ 同 slot）
--   ARGV[1]= n（规则数），其后每规则 3 个参数：rate burst ttl_ms
-- 返回：
--   成功 { 1, tokens_1, wait_1, tokens_2, wait_2, ... }（扣减后，各桶 tokens/wait）
--   失败 { 0, 规则序号, wait, ... }（不足规则 1-based 序号与各自等待，全桶未动）
-- 注意：浮点必须 tostring 返回，否则 Redis 会把 number 截断成整数。
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
