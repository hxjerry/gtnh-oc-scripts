local filesystem = require("filesystem")
local serialization = require("serialization")
local M = {}
function M.open(path)
  local interrupted = filesystem.exists(path)
  if interrupted then
    local file, why = io.open(path, "rb")
    assert(file, why)
    local text = file:read("*a")
    file:close()
    local state = serialization.unserialize(text)
    -- Unreadable or interrupted saves are treated as unsafe, never as idle.
    interrupted = type(state) ~= "table" or state.dirty ~= false
  end
  if filesystem.exists(path .. ".tmp") then interrupted = true end
  local function save(dirty, recipe)
    local parent = filesystem.path(path)
    if not filesystem.exists(parent) then
      assert(filesystem.makeDirectory(parent), "Cannot create journal directory")
    end
    local tmp = path .. ".tmp"
    local file, why = io.open(tmp, "wb")
    assert(file, why)
    local ok, err = file:write(serialization.serialize({dirty = dirty, recipe = recipe}))
    local closed, closeError = file:close()
    assert(ok and closed, err or closeError)
    -- OpenOS rename on the same filesystem replaces the old file.
    local renamed, renameError = filesystem.rename(tmp, path)
    assert(renamed, "Journal save failed: " .. tostring(renameError))
  end
  return save, interrupted
end
return M
