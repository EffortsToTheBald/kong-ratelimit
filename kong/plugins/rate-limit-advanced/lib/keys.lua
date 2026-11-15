-- ============================================================
-- rate-limit-advanced / lib/keys.lua
-- Redis Key 构造（关口四任务 A：维度值无歧义编码 + Lease 键同 hash tag）。
--
-- 无歧义性（设计依据 docs/REMEDIATION.md 关口四）：
--   * 维度值经 encode_value 转义 4 个歧义字节：':'→%3A、'%'→%25、
--     '{'→%7B、'}'→%7D；其余字节原样（Redis key 二进制安全）。
--   * 值内不再含 ':' ⇒ "dim=val" 段间分隔无歧义（多维组合不碰撞）；
--   * 值内不再含 '{' '}' ⇒ hash tag（首个 '{' 至其后首个 '}'）结构
--     只由桶键骨架决定，维度值不可能破坏 tag；
--   * 值内不再含 '%' ⇒ 编码无二次解码歧义。
--   * 同输入恒定输出（纯函数，无随机/时间依赖）。
-- 尚未处理（范围外，维持记录）：MAX_DIM_VALUE_LEN 截断碰撞（N1）。
-- ============================================================

local _M = {}

local ESCAPE_58 = "%3A"   -- ':'
local ESCAPE_37 = "%25"   -- '%'
local ESCAPE_123 = "%7B"  -- '{'
local ESCAPE_125 = "%7D"  -- '}'

local AMBIGUOUS = "[{}%%:]"   -- Lua pattern：任一歧义字节出现才需要逐字节转义

--- 维度值无歧义编码。快路径：不含歧义字节时原样返回（热路径零开销）。
-- @return 编码后的字符串（同输入恒定）
function _M.encode_value(s)
  if type(s) ~= "string" then
    s = tostring(s)
  end
  if not string.find(s, AMBIGUOUS) then
    return s
  end
  local out = {}
  for i = 1, #s do
    local b = string.byte(s, i)
    if b == 58 then
      out[#out + 1] = ESCAPE_58
    elseif b == 37 then
      out[#out + 1] = ESCAPE_37
    elseif b == 123 then
      out[#out + 1] = ESCAPE_123
    elseif b == 125 then
      out[#out + 1] = ESCAPE_125
    else
      out[#out + 1] = string.char(b)
    end
  end
  return table.concat(out)
end

--- Lease 键构造：与对应桶键共用同一 hash tag（追加段，不新增花括号）
-- ⇒ Redis Cluster 下两者落在同一 slot（CROSSSLOT 消除）。
-- RETURN 路径（redis/return_lease.lua，KEYS[1]=Lease 键 / KEYS[2]=桶键，
-- 与 GRANT_LEASE 的 KEYS[1]=桶键 / KEYS[2]=Lease 键 相反）使用同一构造规则。
-- lease_id 输入规范：非空字符串，且不得含 '{' '}' '%'（含则拒绝，返回明确
-- 错误 ⇒ 调用方按既有故障分支 Fail-close，零写入）；':' 为 lease_id 分段
-- 分隔符，允许原样出现。
-- @return key | nil, err
function _M.build_lease_key(bucket_key, lease_id)
  if type(bucket_key) ~= "string" or bucket_key == "" then
    return nil, "bucket_key required"
  end
  if type(lease_id) ~= "string" or lease_id == "" then
    return nil, "lease_id required"
  end
  if string.find(lease_id, "[{}%%]") then
    return nil, "lease_id contains invalid characters: " .. lease_id
  end
  return bucket_key .. ":lease:" .. lease_id
end

return _M
