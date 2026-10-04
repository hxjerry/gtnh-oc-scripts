local filesystem = require("filesystem")
local serialization = require("serialization")
local M = {}
function M.open(path)
  local interrupted = filesystem.exists(path)
  local stageRecord
  if interrupted then
    local file, why = io.open(path, "rb")
    assert(file, why)
    local text = file:read("*a")
    file:close()
    local state = serialization.unserialize(text)
    -- Unreadable or interrupted saves are treated as unsafe, never as idle.
    interrupted = type(state) ~= "table" or state.dirty ~= false
    if type(state) == "table" and interrupted then stageRecord = state.staging end
  end
  if filesystem.exists(path .. ".tmp") then interrupted = true end
  local function save(dirty, recipe, staging)
    local parent = filesystem.path(path)
    if not filesystem.exists(parent) then
      assert(filesystem.makeDirectory(parent), "Cannot create journal directory")
    end
    local tmp = path .. ".tmp"
    local file, why = io.open(tmp, "wb")
    assert(file, why)
    local ok, err = file:write(serialization.serialize({dirty = dirty, recipe = recipe, staging = staging}))
    local flushed, flushError = file:flush()
    local closed, closeError = file:close()
    assert(ok, err)
    assert(flushed, "Journal flush failed: " .. tostring(flushError))
    assert(closed ~= false and closeError == nil, "Journal close failed: " .. tostring(closeError))
    -- OpenOS rename on the same filesystem replaces the old file.
    local renamed, renameError = filesystem.rename(tmp, path)
    assert(renamed, "Journal save failed: " .. tostring(renameError))
  end
  return save, interrupted, stageRecord
end
return M
