-- Items match registry name, metadata and opaque NBT; fluids match registry name only.
local M = {}
local function field(value)
  value = tostring(value)
  return #value .. ":" .. value
end
local function finite(value)
  return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function M.fromStack(stack, kind)
  assert(type(stack) == "table" and type(stack.name) == "string" and stack.name ~= "", "Missing registry name")
  kind = kind or stack.kind or "item"
  assert(kind == "item" or kind == "fluid", "Unknown product kind")
  if kind == "fluid" then
    return {kind = "fluid", name = stack.name, hasTag = false, label = stack.label or stack.name}
  end
  assert(type(stack.hasTag) == "boolean", "NBT visibility unknown for " .. stack.name)
  if stack.hasTag then
    assert(type(stack.tag) == "string" and #stack.tag > 0,
      "NBT unavailable for " .. stack.name .. "; enable OpenComputers allowItemStackNBTTags")
  else
    assert(stack.tag == nil, "Contradictory NBT descriptor for " .. stack.name)
  end
  local d = {kind = kind, name = stack.name, hasTag = stack.hasTag,
    tag = stack.hasTag and stack.tag or nil, label = stack.label or stack.name}
  assert(finite(stack.damage) and stack.damage >= 0 and stack.damage % 1 == 0, "Missing item metadata for " .. stack.name)
  d.damage = stack.damage
  return d
end
function M.key(d)
  local v = M.fromStack(d)
  return field(v.kind) .. field(v.name) .. field(v.damage or "") .. field(v.hasTag and v.tag or "") .. (v.hasTag and "T" or "N")
end
function M.same(a, b)
  return M.key(a) == M.key(b)
end
function M.fingerprint(d)
  -- Display aid only; never used for matching or persistence keys.
  local h = 0
  local key = M.key(d)
  for i = 1, #key do h = (h * 31 + key:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end
function M.describe(d)
  if d.kind == "fluid" then return d.name .. " [fluid, mB]" end
  return d.name .. ":" .. tostring(d.damage) ..
    (d.hasTag and " [NBT " .. M.fingerprint(d) .. ", " .. #d.tag .. " bytes]" or " [no NBT]")
end
function M.filter(d)
  M.fromStack(d)
  if d.kind == "fluid" then return {name = d.name} end
  local filter = {name = d.name, hasTag = d.hasTag, damage = d.damage}
  if d.hasTag then filter.tag = d.tag end
  return filter
end
function M.detail(d, size)
  assert(d.kind ~= "fluid", "Only item inputs are supported")
  local detail = M.filter(d)
  detail.size = size or 1
  return detail
end
return M
