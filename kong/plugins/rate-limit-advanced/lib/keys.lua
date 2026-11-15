-- ============================================================
-- rate-limit-advanced / lib/keys.lua
-- Redis key construction (Gate 4 task A: unambiguous dimension-value encoding + lease keys sharing the hash tag).
--
-- Unambiguity (basis: docs/REMEDIATION.md Gate 4):
--   * dimension values are escaped via encode_value for the 4 ambiguous bytes: ':'→%3A, '%'→%25,
--     '{'→%7B, '}'→%7D; all other bytes pass through unchanged (Redis keys are binary safe).
--   * values no longer contain ':' ⇒ the "dim=val" segment separator is unambiguous (no collisions across multi-dimension combos);
--   * values no longer contain '{' '}' ⇒ the hash tag structure (first '{' up to the following first '}')
--     is decided solely by the bucket-key skeleton; dimension values cannot break the tag;
--   * values no longer contain '%' ⇒ encoding has no double-decoding ambiguity.
--   * same input always yields the same output (pure function, no random/time dependence).
-- Not yet handled (out of scope, kept on record): MAX_DIM_VALUE_LEN truncation collisions (N1).
-- ============================================================

local _M = {}

local ESCAPE_58 = "%3A"   -- ':'
local ESCAPE_37 = "%25"   -- '%'
local ESCAPE_123 = "%7B"  -- '{'
local ESCAPE_125 = "%7D"  -- '}'

local AMBIGUOUS = "[{}%%:]"   -- Lua pattern: escape byte by byte only when any ambiguous byte appears

--- Unambiguous encoding of a dimension value. Fast path: return unchanged when no ambiguous byte is present (zero overhead on the hot path).
-- @return the encoded string (constant for the same input)
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

--- Lease key construction: shares the same hash tag as the corresponding bucket key (appended segment, no new braces)
-- ⇒ both land in the same slot under Redis Cluster (eliminates CROSSSLOT).
-- The RETURN path (redis/return_lease.lua, KEYS[1]=lease key / KEYS[2]=bucket key,
-- reversed from GRANT_LEASE's KEYS[1]=bucket key / KEYS[2]=lease key) uses the same construction rule.
-- lease_id input contract: non-empty string, must not contain '{' '}' '%' (reject if present, returning a clear
-- error ⇒ the caller Fail-closes via the existing fault branch, zero writes); ':' is the lease_id segment
-- separator and is allowed as-is.
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
