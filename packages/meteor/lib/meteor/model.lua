local identity = require("meteor.identity")
local M = {}
function M.recipe(catalog, id)
  for _, recipe in ipairs(catalog.recipes) do
    if recipe.id == id then return recipe end
  end
  error("Unknown meteor: " .. tostring(id))
end
function M.aggregate(config, catalog)
  local byKey, rows = {}, {}
  for _, recipe in ipairs(catalog.recipes) do
    local seen = {}
    for _, ore in ipairs(recipe.ores) do
      for _, product in ipairs(config.oreProducts[ore.key] or {}) do
        local key = identity.key(product)
        local row = byKey[key]
        if not row then
          row = {key = key, product = identity.fromStack(product), meteors = {}}
          byKey[key], rows[#rows + 1] = row, row
        end
        if not seen[key] then
          row.meteors[#row.meteors + 1], seen[key] = recipe.id, true
        end
      end
    end
  end
  for _, row in ipairs(rows) do
    table.sort(row.meteors)
    row.policy = config.policies[row.key] or {active = false, target = 0, meteor = row.meteors[1], craft = false}
    row.validMeteor = false
    for _, id in ipairs(row.meteors) do
      if id == row.policy.meteor then row.validMeteor = true end
    end
  end
  table.sort(rows, function(a, b)
    local al, bl = a.product.label:lower(), b.product.label:lower()
    return al == bl and a.key < b.key or al < bl
  end)
  return rows
end
function M.validate(config, catalog)
  local ores = {}
  for _, r in ipairs(catalog.recipes) do
    for _, o in ipairs(r.ores) do ores[o.key] = true end
  end
  for ore, entries in pairs(config.oreProducts) do
    assert(ores[ore], "Unknown ore mapping: " .. ore)
    local seen = {}
    for _, entry in ipairs(entries) do
      local key = identity.key(entry)
      assert(not seen[key], "Duplicate product mapping for " .. ore)
      seen[key] = true
    end
  end
  for _, row in ipairs(M.aggregate(config, catalog)) do
    assert(not row.policy.active or row.validMeteor, "Selected meteor no longer produces " .. row.product.label)
  end
  return true
end
function M.eachDeficit(rows, after, visit)
  if #rows == 0 then return end
  local start = 0
  for i, row in ipairs(rows) do if row.key == after then start = i end end
  for offset = 1, #rows do
    local row = rows[(start + offset - 1) % #rows + 1]
    if row.policy.active and row.validMeteor and row.stock ~= nil and row.stock < row.policy.target then
      if visit(row) == false then return end
    end
  end
end
function M.choose(rows, after)
  local chosen
  M.eachDeficit(rows, after, function(row)
    chosen = {recipe = row.policy.meteor, craft = row.policy.craft, key = row.key}
    return false
  end)
  return chosen
end
return M
