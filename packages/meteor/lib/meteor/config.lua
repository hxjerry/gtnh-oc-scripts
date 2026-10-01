local serialization = require("serialization")
local filesystem = require("filesystem")

local M = {}


function M.defaults()
  return {
    version = 1,
    oreProducts = {},
    policies = {},
    hardware = {
      me = "", transposer = "", ritual = "", filler = "",
      sourceSide = 2, orbSide = 0, outputSide = 3,
      orbSlot = 1, focusSlot = 1, catalystSlot = 2, interfaceSlot = 1,
      ritualSide = 1, fillerOutSide = 1, fillerInSide = 2, owner = ""
    },
    reserveLP = 100000,
    meteorWait = 15,
    inputTimeout = 300,
    miningTimeout = 3600,
    fillerTimeout = 300,
    fillerStartDelay = 1,
    craftTimeout = 300,
    cooldown = 60,
    useCatalyst = true,
    manualCraft = false
  }
end

local function fail(message)
  error("invalid meteor config: " .. message, 3)
end

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value, minimum, maximum)
  return finite(value) and value == math.floor(value) and value >= minimum and (not maximum or value <= maximum)
end

local function descriptor(value, path)
  if type(value) ~= "table" then fail(path .. " must be a descriptor") end
  if value.kind ~= "item" and value.kind ~= "fluid" then fail(path .. ".kind must be item or fluid") end
  if type(value.name) ~= "string" or value.name == "" then fail(path .. ".name must be a non-empty registry name") end
  if value.kind == "item" and not integer(value.damage, 0) then fail(path .. ".damage must be a non-negative integer") end
  if type(value.hasTag) ~= "boolean" then fail(path .. ".hasTag must be boolean") end
  if value.hasTag then
    if type(value.tag) ~= "string" or #value.tag == 0 then fail(path .. ".tag must preserve a non-empty binary NBT string") end
  elseif value.tag ~= nil then
    fail(path .. ".tag must be absent when hasTag is false")
  end
  if value.kind == "fluid" and value.hasTag then fail(path .. " fluid identity is registry-name-only") end
  if value.label ~= nil and type(value.label) ~= "string" then fail(path .. ".label must be text") end
end

local function map(value, name, validator)
  if type(value) ~= "table" then fail(name .. " must be a table") end
  for key, child in pairs(value) do
    if type(key) ~= "string" or key == "" then fail(name .. " keys must be non-empty strings") end
    validator(child, name .. "[" .. key .. "]")
  end
end

function M.validate(config)
  if type(config) ~= "table" then fail("root must be a table") end
  if config.version ~= 1 then fail("unsupported version") end
  if type(config.useCatalyst) ~= "boolean" or type(config.manualCraft) ~= "boolean" then
    fail("useCatalyst and manualCraft must be boolean")
  end
  if not finite(config.reserveLP) or config.reserveLP < 0 or config.reserveLP ~= math.floor(config.reserveLP) then fail("reserveLP must be a non-negative integer") end
  if not finite(config.meteorWait) or config.meteorWait < 15 then fail("meteorWait must be at least 15 seconds") end
  for _, key in ipairs({ "inputTimeout", "miningTimeout", "fillerTimeout", "craftTimeout", "cooldown" }) do
    if not finite(config[key]) or config[key] <= 0 then fail(key .. " must be a finite positive number") end
  end
  if not finite(config.fillerStartDelay) or config.fillerStartDelay < 1 or config.fillerStartDelay >= config.fillerTimeout then
    fail("fillerStartDelay must be at least one second and less than fillerTimeout")
  end

  local hardware = config.hardware
  if type(hardware) ~= "table" then fail("hardware must be a table") end
  for _, key in ipairs({ "me", "transposer", "ritual", "filler", "owner" }) do
    if type(hardware[key]) ~= "string" then fail("hardware." .. key .. " must be text") end
  end
  for _, key in ipairs({ "sourceSide", "orbSide", "outputSide", "ritualSide", "fillerOutSide", "fillerInSide" }) do
    if not integer(hardware[key], 0, 5) then fail("hardware." .. key .. " must be a side from 0 through 5") end
  end
  for _, key in ipairs({ "orbSlot", "focusSlot", "catalystSlot", "interfaceSlot" }) do
    if not integer(hardware[key], 1) then fail("hardware." .. key .. " must be a positive slot") end
  end
  if hardware.ritual ~= "" and hardware.filler ~= "" and hardware.ritual == hardware.filler then
    fail("ritual and filler addresses must be distinct")
  end
  if hardware.sourceSide == hardware.orbSide or hardware.sourceSide == hardware.outputSide or hardware.orbSide == hardware.outputSide then
    fail("source, orb, and output sides must be distinct")
  end
  if hardware.fillerOutSide == hardware.fillerInSide then
    fail("filler output and completion input sides must be distinct")
  end
  if hardware.focusSlot == hardware.catalystSlot then
    fail("focus and catalyst slots must be distinct")
  end

  map(config.oreProducts, "oreProducts", function(products, path)
    if type(products) ~= "table" then fail(path .. " must be an array") end
    local count = 0
    for index, product in pairs(products) do
      if not integer(index, 1) then fail(path .. " must use consecutive positive array indices") end
      count = count + 1
      descriptor(product, path .. "[" .. index .. "]")
    end
    for index = 1, count do if products[index] == nil then fail(path .. " must not contain array holes") end end
  end)
  map(config.policies, "policies", function(policy, path)
    if type(policy) ~= "table" then fail(path .. " must be a table") end
    if type(policy.active) ~= "boolean" or type(policy.craft) ~= "boolean" then fail(path .. ".active and .craft must be boolean") end
    if not integer(policy.target, 0) then fail(path .. ".target must be a non-negative integer") end
    if policy.meteor ~= nil and type(policy.meteor) ~= "string" then fail(path .. ".meteor must be text") end
  end)
  return true
end

local function readFile(path)
  local file, reason = io.open(path, "rb")
  if not file then error("cannot read config " .. path .. ": " .. tostring(reason), 2) end
  local contents, readReason = file:read("*a")
  local closed, closeReason = file:close()
  if contents == nil then error("cannot read config " .. path .. ": " .. tostring(readReason), 2) end
  if closed == false or closeReason ~= nil then error("cannot close config " .. path .. ": " .. tostring(closeReason), 2) end
  return contents
end

function M.load(path)
  if type(path) ~= "string" or path == "" then error("config path required", 2) end
  if not filesystem.exists(path) then return M.defaults() end
  local contents = readFile(path)
  local ok, config = pcall(serialization.unserialize, contents)
  if not ok or type(config) ~= "table" then error("cannot decode config " .. path .. ": " .. tostring(config), 2) end
  M.validate(config)
  return config
end

local function writeFile(path, contents)
  local file, reason = io.open(path, "wb")
  if not file then error("cannot open temporary config " .. path .. ": " .. tostring(reason), 2) end
  local ok, writeReason = file:write(contents)
  if not ok then
    file:close()
    error("cannot write temporary config " .. path .. ": " .. tostring(writeReason), 2)
  end
  local flushed, flushReason = file:flush()
  local closed, closeReason = file:close()
  if not flushed then error("cannot flush temporary config " .. path .. ": " .. tostring(flushReason), 2) end
  if closed == false or closeReason ~= nil then error("cannot close temporary config " .. path .. ": " .. tostring(closeReason), 2) end
end

function M.save(path, config)
  if type(path) ~= "string" or path == "" then error("config path required", 2) end
  M.validate(config)
  local ok, contents = pcall(serialization.serialize, config)
  if not ok or type(contents) ~= "string" then error("cannot serialize config: " .. tostring(contents), 2) end
  local parent = filesystem.path(path)
  if parent and parent ~= "" and not filesystem.exists(parent) then
    local made, reason = filesystem.makeDirectory(parent)
    if not made and not filesystem.exists(parent) then error("cannot create config directory " .. parent .. ": " .. tostring(reason), 2) end
  end
  local temporary = path .. ".tmp"
  if filesystem.exists(temporary) and not filesystem.remove(temporary) then error("cannot remove stale temporary config " .. temporary, 2) end
  writeFile(temporary, contents)
  -- OC filesystem rename is atomic and replaces the destination on the same filesystem.
  local moved, reason = filesystem.rename(temporary, path)
  if not moved then
    filesystem.remove(temporary)
    error("cannot install config: " .. tostring(reason), 2)
  end
  return true
end

return M
