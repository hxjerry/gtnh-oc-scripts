local configModule = require("meteor.config")
local identity = require("meteor.identity")
local model = require("meteor.model")
local unicode = require("unicode")

local M = {}
local WIDTH, HEIGHT = 160, 50
local KEY = { esc = 1, enter = 28, backspace = 14, tab = 15, up = 200, down = 208, left = 203, right = 205, pageup = 201, pagedown = 209, home = 199, finish = 207 }
local COLORS = { bg = 0x101820, panel = 0x1B2935, white = 0xE8EEF2, muted = 0x8DA2B0, cyan = 0x53D8D1, green = 0x7DE38D, yellow = 0xF1C75B, red = 0xFF7272, blue = 0x76A9FA }
local PAGE_SIZE = 18

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, child in pairs(value) do out[key] = copy(child) end
  return out
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function size(value)
  local ok, result = pcall(unicode.wlen, tostring(value or ""))
  return ok and result or #tostring(value or "")
end

local function slice(value, first, last)
  local ok, result = pcall(unicode.sub, tostring(value or ""), first, last)
  return ok and result or tostring(value or ""):sub(first, last)
end


local function sourceOres(catalog)
  local byKey, rows = {}, {}
  local function add(ore, fallbackKey)
    if type(ore) ~= "table" then return end
    local key = ore.key or fallbackKey
    if type(key) ~= "string" or key == "" or byKey[key] then return end
    local source = catalog.source
    local sourceEntry
    if type(source) == "table" then
      if type(source[key]) == "table" then sourceEntry = source[key] end
      for _, entry in pairs(source) do
        if type(entry) == "table" and entry.key == key then sourceEntry = entry; break end
      end
    end
    local label = ore.label or ore.displayName or ore.name
    if not label and sourceEntry then label = sourceEntry.label or sourceEntry.displayName or sourceEntry.name end
    if not label then label = key end
    local row = {key = key, label = tostring(label), ore = ore, source = sourceEntry}
    byKey[key] = row
    rows[#rows + 1] = row
  end
  for _, recipe in ipairs(catalog.recipes or {}) do
    for _, ore in ipairs(recipe.ores or {}) do add(ore) end
  end
  table.sort(rows, function(a, b) return a.label:lower() == b.label:lower() and a.key < b.key or a.label:lower() < b.label:lower() end)
  return rows
end

local function formatDescriptor(descriptor)
  local ok, readable = pcall(identity.describe, descriptor)
  if not ok then return "[invalid identity] " .. tostring(descriptor and descriptor.name or "?") end
  local label = descriptor.label or descriptor.name
  return tostring(label) .. " — " .. readable
end

local function formatAmount(value, descriptor)
  if value == nil then return "?" end
  if descriptor and descriptor.kind == "fluid" then return tostring(value) .. " mB" end
  return tostring(value) .. " items"
end

local function truth(value)
  return value and "YES" or "no"
end

function M.new(gpu, config, catalog, callbacks)
  assert(gpu and type(config) == "table" and type(catalog) == "table", "gpu, config and catalog are required")
  callbacks = callbacks or {}
  local self = {
    gpu = gpu, config = config, catalog = catalog, callbacks = callbacks,
    screen = "home", selected = 1, scroll = 0, filters = {}, message = nil,
    closed = false, view = {}, discovered = nil, editTarget = nil,
    pendingOre = nil, pendingRecipe = nil,
    policyKey = nil, confirmAction = nil, prompt = nil
  }
  local ok, width, height = pcall(gpu.getResolution)
  assert(ok and width and height, "GPU resolution unavailable")
  self.oldResolution = {width, height}
  local gotForeground, foreground, foregroundPalette = pcall(gpu.getForeground)
  local gotBackground, background, backgroundPalette = pcall(gpu.getBackground)
  if gotForeground then self.oldForeground = {foreground, foregroundPalette} end
  if gotBackground then self.oldBackground = {background, backgroundPalette} end
  local hasMaxDepth, maxDepth = pcall(gpu.maxDepth)
  assert(hasMaxDepth and maxDepth and maxDepth >= 8, "Meteor UI requires an 8-bit-capable GPU", 2)
  local gotDepth, depth = pcall(gpu.getDepth)
  if gotDepth and depth then self.oldDepth = depth end
  if gotDepth and depth ~= 8 then gpu.setDepth(8) end
  -- OC returns false when the requested resolution is already active.
  local _, reason = gpu.setResolution(WIDTH, HEIGHT)
  local actualWidth, actualHeight = gpu.getResolution()
  assert(actualWidth == WIDTH and actualHeight == HEIGHT,
    "cannot set GPU resolution to 160x50: " .. tostring(reason or "resolution did not take effect"))

  function self:put(x, y, text, color, background)
    if y < 1 or y > HEIGHT or x > WIDTH then return end
    text = tostring(text or "")
    if x < 1 then text = slice(text, 2 - x); x = 1 end
    local max = WIDTH - x + 1
    if size(text) > max then
      local truncated = unicode.wtrunc and unicode.wtrunc(text, max) or slice(text, 1, max)
      text = truncated
    end
    if color then self.gpu.setForeground(color) end
    if background then self.gpu.setBackground(background) end
    self.gpu.set(x, y, text)
  end

  function self:clear()
    self.gpu.setBackground(COLORS.bg)
    self.gpu.setForeground(COLORS.white)
    self.gpu.fill(1, 1, WIDTH, HEIGHT, " ")
  end

  function self:header(title)
    self:put(2, 1, "METEOR  /  " .. title, COLORS.cyan)
    self:put(1, 2, string.rep("─", WIDTH), COLORS.muted)
  end

  function self:footer(text)
    self:put(1, HEIGHT - 1, string.rep("─", WIDTH), COLORS.muted)
    self:put(2, HEIGHT, text or "↑↓ select   Enter open   Esc back   / filter   PgUp/PgDn page", COLORS.muted)
  end

  function self:notice()
    local errorText = self.message or self.view.lastError
    if errorText then self:put(2, 3, "! " .. tostring(errorText), COLORS.red) end
  end

  function self:setScreen(name)
    self.screen, self.selected, self.scroll = name, 1, 0
  end

  function self:busy()
    local state, mode = tostring(self.view.state or ""):lower(), tostring(self.view.mode or ""):lower()
    -- Saves are accepted only while stopped; FAULT is deliberately editable for recovery.
    if mode ~= "" and mode ~= "stopped" and mode ~= "fault" then return true end
    if state == "fault" or mode == "fault" then return false end
    return state ~= "" and state ~= "stopped" and state ~= "ready" and state ~= "idle"
  end

  function self:mutate(change)
    if self:busy() then self.message = "Stop the active operation before changing settings."; return false end
    local before = copy(self.config)
    local ok, reason = pcall(change)
    if ok then ok, reason = pcall(configModule.validate, self.config) end
    if ok then ok, reason = pcall(model.validate, self.config, self.catalog) end
    if ok then
      local saveCallback = self.callbacks.save
      if type(saveCallback) ~= "function" then ok, reason = false, "Save callback is unavailable" else
        local saveOk, result, extra = pcall(saveCallback)
        if not saveOk then ok, reason = false, result elseif result == false then ok, reason = false, extra or "Save failed" end
      end
    end
    if not ok then
      for key in pairs(self.config) do self.config[key] = nil end
      for key, value in pairs(before) do self.config[key] = value end
      self.message = tostring(reason)
      return false
    end
    self.message = "Settings saved."
    return true
  end

  function self:saveBeforeAction()
    local ok, reason = pcall(configModule.validate, self.config)
    if ok then ok, reason = pcall(model.validate, self.config, self.catalog) end
    if not ok then self.message = tostring(reason); return false end
    local callback = self.callbacks.save
    if type(callback) ~= "function" then self.message = "Save callback is unavailable"; return false end
    local called, result, extra = pcall(callback)
    if not called then self.message = tostring(result); return false end
    if result == false then self.message = tostring(extra or "Save failed"); return false end
    return true
  end

  function self:call(name, ...)
    local callback = self.callbacks[name]
    if type(callback) ~= "function" then self.message = name .. " callback is unavailable"; return false end
    -- Stop and shutdown are emergency paths: never gate them on a settings save.
    if name ~= "stop" and name ~= "shutdown" and not self:saveBeforeAction() then return false end
    local okCall, result, extra = pcall(callback, ...)
    if not okCall then self.message = tostring(result); return false end
    if result == false then self.message = tostring(extra or (name .. " failed")); return false end
    self.message = name .. " requested."
    return true
  end

  function self:entries()
    if self.screen == "menu" then
      return {
        {label = "Hardware setup", action = function() self:setScreen("hardware") end},
        {label = "Ore → product mappings", action = function() self:setScreen("ores") end},
        {label = "All machine statuses", action = function() self:setScreen("machines") end},
        {label = "Product policies", action = function() self:setScreen("policies") end},
        {label = "Manual meteor recipe", action = function() self:setScreen("recipes") end},
        {label = "Controller settings", action = function() self:setScreen("settings") end},
        {label = "Automatic mode", action = function() self:call("auto"); self:setScreen("home") end},
        {label = "Stop active operation", action = function() self:call("stop"); self:setScreen("home") end},
        {label = "Reset / recovery (safety acknowledgement)", action = function() self.confirmAction = "reset"; self:setScreen("confirm") end},
        {label = "Save settings", action = function() self:saveBeforeAction(); self:setScreen("home") end},
        {label = "Quit", action = function() self.confirmAction = "shutdown"; self:setScreen("confirm") end}
      }
    elseif self.screen == "hardware" then
      local fields = {
        {"ME address", "me", "me", "address"}, {"Transposer address", "transposer", "transposer", "address"},
        {"Ritual output activator address", "ritual", "redstone", "address"},
        {"Filler component address", "filler", "redstone", "address"},
        {"Source side (0-5)", "sourceSide", nil, "number"}, {"Orb side (0-5)", "orbSide", nil, "number"},
        {"Output side (0-5)", "outputSide", nil, "number"}, {"Orb slot", "orbSlot", nil, "number"},
        {"Focus slot", "focusSlot", nil, "number"}, {"Catalyst slot", "catalystSlot", nil, "number"},
        {"Interface slot", "interfaceSlot", nil, "number"}, {"Ritual side (0-5)", "ritualSide", nil, "number"},
        {"Filler output side (0-5)", "fillerOutSide", nil, "number"}, {"Filler input side (0-5)", "fillerInSide", nil, "number"},
        {"Exact orb owner name (must match crystal)", "owner", nil, "text"}
      }
      local out = {}
      for _, field in ipairs(fields) do
        local key = field[2]
        out[#out + 1] = {label = field[1] .. "  =  " .. tostring(self.config.hardware[key]), action = function()
          self.editTarget, self.addressCategory = key, field[3]
          if field[4] == "address" then self:discoverFor(key) else self:openPrompt("hardware", key, tostring(self.config.hardware[key]), field[4]) end
        end}
      end
      out[#out + 1] = {label = "Save settings", action = function() self:saveBeforeAction() end}
      return out
    elseif self.screen == "settings" then
      local fields = {
        {"Reserve LP", "reserveLP", "number"}, {"Meteor wait (seconds)", "meteorWait", "number"},
        {"Input timeout (seconds)", "inputTimeout", "number"}, {"Mining timeout (seconds)", "miningTimeout", "number"},
        {"Filler timeout (seconds)", "fillerTimeout", "number"}, {"Filler input settle (seconds)", "fillerStartDelay", "number"},
        {"Craft timeout (seconds)", "craftTimeout", "number"},
        {"Cooldown (seconds)", "cooldown", "number"}
      }
      local out = {}
      for _, field in ipairs(fields) do
        local key = field[2]
        out[#out + 1] = {label = field[1] .. "  =  " .. tostring(self.config[key]), action = function()
          self:openPrompt("settings", key, tostring(self.config[key]), field[3])
        end}
      end
      out[#out + 1] = {label = "Use catalyst globally  =  " .. truth(self.config.useCatalyst), action = function()
        self:mutate(function() self.config.useCatalyst = not self.config.useCatalyst end)
      end}
      out[#out + 1] = {label = "Autocraft missing inputs  =  " .. truth(self.config.manualCraft), action = function()
        self:mutate(function() self.config.manualCraft = not self.config.manualCraft end)
      end}
      out[#out + 1] = {label = "Save settings", action = function() self:saveBeforeAction() end}
      return out
    elseif self.screen == "machines" then
      local out = {}
      for index, plant in ipairs(self.view.plants or {}) do
        out[#out + 1] = {label = tostring(index) .. ".  " .. tostring(plant.address or "plant") .. "  /  " .. tostring(plant.status or "unknown")}
      end
      if #out == 0 then out[1] = {label = "No machine status reported yet.", action = function() end} end
      return out
    elseif self.screen == "addresses" then
      local result = {}
      local choices = self.addressChoices or {}
      for _, choice in ipairs(choices) do
        result[#result + 1] = {label = choice.label, action = function()
          if choice.address then self:setHardwareAddress(choice.address) elseif choice.manual then self:openPrompt("hardware", self.editTarget, "", "text") end
        end}
      end
      return result
    elseif self.screen == "ores" then
      local ores = sourceOres(self.catalog)
      local filter = (self.filters.ores or ""):lower()
      local result = {}
      for _, ore in ipairs(ores) do
        local mapped = self.config.oreProducts[ore.key] or {}
        local label = ore.label .. "  [" .. #mapped .. " products]  {" .. ore.key .. "}"
        if filter == "" or label:lower():find(filter, 1, true) then
          result[#result + 1] = {label = label, action = function()
            self.pendingOre = ore
            self:setScreen("mapping")
          end}
        end
      end
      return result
    elseif self.screen == "mapping" then
      local ore = self.pendingOre
      if not ore then return {} end
      local products = self.config.oreProducts[ore.key] or {}
      local result = {}
      for _, product in ipairs(products) do
        result[#result + 1] = {label = formatDescriptor(product), action = function()
          self.message = "Mapped product: " .. formatDescriptor(product)
        end}
      end
      result[#result + 1] = {label = "+ Add ME item product", action = function() self:beginBrowse("item") end}
      result[#result + 1] = {label = "+ Add ME fluid product", action = function() self:beginBrowse("fluid") end}
      return result
    elseif self.screen == "browse" then
      local result, filter = {}, (self.filters.browse or ""):lower()
      for _, descriptor in ipairs(self.browseRows or {}) do
        local label = formatDescriptor(descriptor)
        if filter == "" or label:lower():find(filter, 1, true) then
          result[#result + 1] = {label = label, action = function() self:addProduct(descriptor) end}
        end
      end
      return result
    elseif self.screen == "policies" then
      local rows = self.view.rows or {}
      if #rows == 0 then
        local ok, result = pcall(model.aggregate, self.config, self.catalog)
        rows = ok and result or {}
      end
      local filter = (self.filters.policies or ""):lower()
      local result = {}
      for _, row in ipairs(rows) do
        local label = formatDescriptor(row.product) .. "  [" .. (row.policy.active and "ACTIVE" or "off") .. ", target " .. tostring(row.policy.target) .. "]"
        if filter == "" or label:lower():find(filter, 1, true) then
          result[#result + 1] = {label = label, action = function() self.policyKey = row.key; self:setScreen("policyedit") end, row = row}
        end
      end
      return result
    elseif self.screen == "policyedit" then
      local row = self:policyRow()
      if not row then return {} end
      local policy = self.config.policies[row.key] or row.policy
      return {
        {label = "Active  =  " .. truth(policy.active), action = function()
          self:mutate(function()
            local nextPolicy = copy(self.config.policies[row.key] or row.policy)
            nextPolicy.active = not nextPolicy.active
            self.config.policies[row.key] = nextPolicy
          end)
        end},
        {label = "Target  =  " .. formatAmount(policy.target, row.product), action = function()
          self:openPrompt("policyTarget", row.key, tostring(policy.target), "number")
        end},
        {label = "Selected meteor  =  " .. tostring(policy.meteor or "(none)"), action = function() self:setScreen("meteorChoices") end},
        {label = "Autocraft missing inputs  =  " .. truth(policy.craft), action = function()
          self:mutate(function()
            local nextPolicy = copy(self.config.policies[row.key] or row.policy)
            nextPolicy.craft = not nextPolicy.craft
            self.config.policies[row.key] = nextPolicy
          end)
        end}
      }
    elseif self.screen == "meteorChoices" then
      local row = self:policyRow()
      local result = {}
      if row then for _, id in ipairs(row.meteors) do
        local recipe = model.recipe(self.catalog, id)
        result[#result + 1] = {label = id .. " — " .. tostring(recipe.label), action = function()
          self:mutate(function()
            local policy = copy(self.config.policies[row.key] or row.policy)
            policy.meteor = id
            self.config.policies[row.key] = policy
          end)
          self:setScreen("policyedit")
        end}
      end end
      return result
    elseif self.screen == "recipes" then
      local result, filter = {}, (self.filters.recipes or ""):lower()
      for _, recipe in ipairs(self.catalog.recipes or {}) do
        local unsafe = recipe.ore_miner and recipe.ore_miner.safe_candidate == false
        local label = (unsafe and "⚠ NON-ORE / UNSAFE: " or "") .. recipe.label .. "  [" .. recipe.id .. "]"
        if filter == "" or label:lower():find(filter, 1, true) then
          result[#result + 1] = {label = label, action = function() self.pendingRecipe = recipe; self.detailOrePage = 0; self:setScreen("recipeDetail") end}
        end
      end
      return result
    elseif self.screen == "recipeDetail" then
      local recipe = self.pendingRecipe
      if not recipe then return {} end
      return {
        {label = "Run once", action = function() self:call("run", recipe.id, false) end},
        {label = "Run in loop", action = function() self:call("run", recipe.id, true) end},
        {label = "Global catalyst  =  " .. truth(self.config.useCatalyst), action = function()
          self:mutate(function() self.config.useCatalyst = not self.config.useCatalyst end)
        end},
        {label = "Autocraft missing inputs  =  " .. truth(self.config.manualCraft), action = function()
          self:mutate(function() self.config.manualCraft = not self.config.manualCraft end)
        end}
      }
    end
    return {}
  end

  function self:policyRow()
    local rows = self.view.rows
    if type(rows) ~= "table" or #rows == 0 then rows = model.aggregate(self.config, self.catalog) end
    for _, row in ipairs(rows) do if row.key == self.policyKey then return row end end
  end

  function self:openPrompt(kind, target, value, valueType)
    self.prompt = {kind = kind, target = target, text = tostring(value or ""), valueType = valueType or "text", priorScreen = self.screen}
    self:setScreen("prompt")
  end

  function self:discoverFor(key)
    local callback = self.callbacks.discover
    if type(callback) ~= "function" then self.message = "Discovery callback is unavailable"; return end
    local okDiscover, result = pcall(callback)
    if not okDiscover then self.message = tostring(result); return end
    if type(result) ~= "table" then self.message = "Discovery returned no device list"; return end
    self.discovered, self.editTarget = result, key
    local categories = {me = "me", transposer = "transposer", ritual = "redstone", filler = "redstone"}
    local category = categories[key]
    self.addressChoices = {}
    local addresses = category and result[category]
    if type(addresses) == "table" then for _, address in ipairs(addresses) do
      if type(address) == "string" and address ~= "" then
        self.addressChoices[#self.addressChoices + 1] = {label = address, address = address}
      elseif type(address) == "table" and type(address.address) == "string" then
        self.addressChoices[#self.addressChoices + 1] = {label = address.address, address = address.address}
      end
    end end
    self.addressChoices[#self.addressChoices + 1] = {label = "Enter address manually…", manual = true}
    if #self.addressChoices == 1 then self.message = "No " .. tostring(category) .. " components discovered; enter address manually." end
    self:setScreen("addresses")
  end

  function self:setHardwareAddress(address)
    local key = self.editTarget
    local prior = self.screen
    local success = self:mutate(function() self.config.hardware[key] = address end)
    self:setScreen("hardware")
    return success
  end

  function self:addProduct(product)
    local ore = self.pendingOre
    if not ore then self.message = "No ore selected"; return end
    local added = self:mutate(function()
      local products = copy(self.config.oreProducts[ore.key] or {})
      local key = identity.key(product)
      for _, existing in ipairs(products) do
        if identity.key(existing) == key then error("That exact product is already mapped for this ore") end
      end
      products[#products + 1] = identity.fromStack(product)
      self.config.oreProducts[ore.key] = products
    end)
    if added then self:setScreen("mapping") end
  end

  function self:beginBrowse(kind)
    local callback = self.callbacks.catalogue
    if type(callback) ~= "function" then self.message = "ME catalogue callback is unavailable"; return end
    local okBrowse, result = pcall(callback, kind)
    if not okBrowse then self.message = tostring(result); return end
    if type(result) ~= "table" then self.message = "ME catalogue returned no descriptors"; return end
    local rows, seen, errors = {}, {}, {}
    for _, descriptor in ipairs(result) do
      local okIdentity, normalized = pcall(identity.fromStack, descriptor)
      if okIdentity and normalized.kind == kind then
        local key = identity.key(normalized)
        if not seen[key] then rows[#rows + 1] = normalized; seen[key] = true end
      elseif not okIdentity then
        errors[#errors + 1] = tostring(normalized)
      end
    end
    table.sort(rows, function(a, b)
      local al, bl = tostring(a.label):lower(), tostring(b.label):lower()
      return al == bl and identity.key(a) < identity.key(b) or al < bl
    end)
    self.browseRows, self.browseErrors = rows, errors
    self.filters.browse = ""
    self:setScreen("browse")
    if #errors > 0 then self.message = #errors .. " ME entries have unknown/unavailable identity; skipped. First: " .. errors[1]
    elseif #rows == 0 then self.message = "No readable " .. kind .. " products returned by ME." end
  end

  function self:confirmPrompt()
    local prompt = self.prompt
    local text = trim(prompt.text)
    if prompt.kind == "filter" then
      self.filters[prompt.target] = text
      self:setScreen(prompt.priorScreen)
      return
    end
    local value = text
    if prompt.valueType == "number" then
      value = tonumber(text)
      if not value or value ~= value or value == math.huge or value == -math.huge then self.message = "Enter a finite number."; return end
      if value % 1 ~= 0 then self.message = "This setting requires a whole number."; return end
    end
    local okChange
    if prompt.kind == "hardware" then
      local minimum = prompt.target:find("Side", 1, true) and 0 or 1
      if prompt.valueType == "number" and value < minimum then self.message = "Value is outside its allowed range."; return end
      if prompt.target:find("Side", 1, true) and value > 5 then self.message = "Sides must be 0 through 5."; return end
      okChange = self:mutate(function() self.config.hardware[prompt.target] = value end)
      self:setScreen("hardware")
    elseif prompt.kind == "settings" then
      if value < 0 then self.message = "Value cannot be negative."; return end
      okChange = self:mutate(function() self.config[prompt.target] = value end)
      self:setScreen("settings")
    elseif prompt.kind == "policyTarget" then
      if value < 0 then self.message = "Target cannot be negative."; return end
      local row = self:policyRow()
      if not row then self.message = "Product is no longer mapped."; return end
      okChange = self:mutate(function()
        local policy = copy(self.config.policies[row.key] or row.policy)
        policy.target = value
        self.config.policies[row.key] = policy
      end)
      self:setScreen("policyedit")
    end
    if okChange then self.message = "Settings saved." end
  end

  function self:drawList(title, subtitle, entries, filterKey)
    self:clear(); self:header(title); self:notice()
    local offsetY = 5
    if subtitle then self:put(2, 4, subtitle, COLORS.muted); offsetY = 6 end
    if filterKey then
      local filter = self.filters[filterKey] or ""
      self:put(2, 4, "Filter: " .. filter .. "_  (/ to edit)", COLORS.yellow)
      offsetY = 6
    end
    local totalPages = math.max(1, math.ceil(#entries / PAGE_SIZE))
    local page = math.floor(self.scroll / PAGE_SIZE) + 1
    local first = (page - 1) * PAGE_SIZE + 1
    local last = math.min(#entries, first + PAGE_SIZE - 1)
    if #entries == 0 then self:put(4, offsetY, "No entries.", COLORS.muted) end
    for index = first, last do
      local line = index - first + offsetY
      local prefix = index == self.selected and " ▶ " or "   "
      local color = index == self.selected and COLORS.cyan or COLORS.white
      self:put(2, line, prefix .. entries[index].label, color)
    end
    self:put(2, 27, string.format("%d entries   page %d/%d", #entries, page, totalPages), COLORS.muted)
    self:footer("↑↓ select  Enter open  / filter  PgUp/PgDn page  Esc back  D remove (mapping)")
  end

  function self:drawHome()
    self:clear(); self:header("DASHBOARD")
    self:notice()
    local mode = tostring(self.view.mode or "idle")
    local state = tostring(self.view.state or "ready")
    self:put(2, 4, "Mode: " .. mode .. "     State: " .. state .. "     LP: " .. tostring(self.view.lp or "?"), COLORS.yellow)
    self:put(2, 5, "Selected meteor: " .. tostring(self.view.recipe or "-") .. "  /  " .. tostring(self.view.detail or ""), COLORS.white)
    self:put(2, 7, "OUTPUTS   Item / fluid                      Current             Target      Active    Meteor         Craft", COLORS.cyan)
    self:put(2, 8, string.rep("─", 156), COLORS.muted)
    local rows = self.view.rows or {}
    local filter = (self.filters.home or ""):lower()
    local visible = {}
    for _, row in ipairs(rows) do
      local label = formatDescriptor(row.product)
      if filter == "" or label:lower():find(filter, 1, true) then visible[#visible + 1] = row end
    end
    local pages = math.max(1, math.ceil(#visible / 18))
    local page = math.floor(self.scroll / 18) + 1
    local first = (page - 1) * 18 + 1
    for index = first, math.min(#visible, first + 17) do
      local row = visible[index]
      local line = index - first + 9
      local prefix = index == self.selected and "▶" or " "
      local label = tostring(row.product.label or row.product.name) .. " [" .. (row.product.kind == "fluid" and "fluid" or tostring(row.product.damage)) .. (row.product.hasTag and ", NBT " .. identity.fingerprint(row.product) or "") .. "]"
      local policy = row.policy or {}
      self:put(2, line, prefix, COLORS.cyan)
      self:put(4, line, slice(label, 1, 60), COLORS.white)
      self:put(67, line, formatAmount(row.stock, row.product), COLORS.white)
      self:put(84, line, formatAmount(policy.target or 0, row.product), COLORS.white)
      self:put(101, line, policy.active and "ON" or "off", policy.active and COLORS.green or COLORS.muted)
      self:put(109, line, tostring(policy.meteor or "-"), COLORS.white)
      self:put(145, line, policy.craft and "yes" or "no", COLORS.white)
    end
    self:put(2, 28, "Rows " .. #visible .. "   page " .. pages .. "  |  Filter: " .. (self.filters.home or "") .. " (/ to edit)", COLORS.muted)
    self:put(2, 30, "ORE DRILLING PLANTS", COLORS.cyan)
    local plants = self.view.plants or {}
    for index = 1, math.min(#plants, 4) do
      local plant = plants[index]
      self:put(3, 30 + index, tostring(plant.address or "plant") .. "  " .. tostring(plant.status or "unknown"), COLORS.white)
    end
    self:put(78, 30, "RECENT LOG", COLORS.cyan)
    local logs = self.view.logs or {}
    local start = math.max(1, #logs - 6)
    local y = 31
    for index = start, #logs do
      self:put(79, y, tostring(logs[index]), COLORS.white); y = y + 1
      if y > 37 then break end
    end
    self:put(2, 39, "Selected: " .. (visible[self.selected] and formatDescriptor(visible[self.selected].product) or "none"), COLORS.muted)
    self:put(2, 41, "[Actions]", COLORS.cyan)
    self:put(17, 41, "[Automatic]", COLORS.green)
    self:put(34, 41, "[Stop]", COLORS.yellow)
    self:put(46, 41, "[Quit]", COLORS.red)
    self:put(2, 43, "Policy edit: Enter   Actions: M   Auto: A   Stop: S   Search: /   Page: PgUp/PgDn", COLORS.muted)
    self:put(2, 45, "OC event-driven interface — dialogs never pull or block events", COLORS.muted)
    self:footer("↑↓ select output  Enter policy  M actions  A automatic  S stop  / filter  PgUp/PgDn page  Q quit")
  end

  function self:drawPrompt()
    self:clear(); self:header("EDIT VALUE")
    self:notice()
    local prompt = self.prompt
    local line = "Value: " .. prompt.text .. "_"
    self:put(3, 7, line, COLORS.yellow)
    self:put(3, 9, "Type a value, Backspace deletes, clipboard paste supported.", COLORS.muted)
    self:put(3, 10, "Enter accepts   Esc cancels", COLORS.muted)
    self:footer("Enter accept   Esc cancel   Backspace delete")
  end

  function self:drawConfirm()
    self:clear(); self:header("CONFIRM ACTION"); self:notice()
    local action = self.confirmAction
    local prompt = action == "shutdown" and "Stop and quit Meteor?" or "Reset after inspection: remove stray focus, MRS inactive, area clear, plants stopped/retracted. Idle filler HIGH is allowed."
    self:put(3, 7, prompt, COLORS.yellow)
    if action == "reset" then
      self:put(3, 9, "Reset acknowledges recovery; it does not resume auto/loop. Ritual uses an edge activator, never direct MRS redstone.", COLORS.red)
      self:put(3, 10, "[Yes]   [No]", COLORS.cyan)
    else
      self:put(3, 9, "[Yes]   [No]", COLORS.cyan)
    end
    self:footer("←/→ choose   Enter confirm   Esc cancel")
  end

  function self:draw(view)
    if self.closed then return end
    if view then self.view = view end
    if self.screen == "home" then self:drawHome()
    elseif self.screen == "prompt" then self:drawPrompt()
    elseif self.screen == "confirm" then self:drawConfirm()
    else
      local entries = self:entries()
      local titles = {menu = "ACTIONS", hardware = "HARDWARE SETUP", machines = "ALL MACHINE STATUSES", settings = "CONTROLLER SETTINGS", addresses = "SELECT COMPONENT ADDRESS", ores = "ORE-PRODUCT MAPPING", mapping = "MAPPED PRODUCTS", browse = "ME NETWORK BROWSER", policies = "PRODUCT POLICIES", policyedit = "EDIT PRODUCT POLICY", meteorChoices = "SELECT METEOR", recipes = "MANUAL METEOR RECIPE", recipeDetail = "RECIPE DETAILS"}
      local subtitle
      if self.screen == "mapping" and self.pendingOre then subtitle = self.pendingOre.label .. "  {" .. self.pendingOre.key .. "}" end
      if self.screen == "recipeDetail" and self.pendingRecipe then
        local recipe = self.pendingRecipe
        subtitle = recipe.label .. "  /  " .. recipe.id .. "  /  Meteor LP " .. tostring(recipe.lp)
      end
      local filters = {ores = "ores", browse = "browse", policies = "policies", recipes = "recipes"}
      self:drawList(titles[self.screen] or "METEOR", subtitle, entries, filters[self.screen])
      if self.screen == "mapping" then self:put(2, 28, "Products identify eligible meteors only. Enter shows identity; D removes; A adds an item.", COLORS.muted) end
      if self.screen == "hardware" then
        self:put(2, 31, "Ritual address is an edge-triggered activator with bound crystal; do not wire it directly to MRS.", COLORS.yellow)
        self:put(2, 32, "Owner must exactly match the activation crystal/orb owner name. Source side is the dedicated ME interface.", COLORS.yellow)
      end
      if self.screen == "recipeDetail" and self.pendingRecipe then
        local recipe = self.pendingRecipe
        self:put(2, 11, "Focus: " .. formatDescriptor(recipe.focus), COLORS.muted)
        self:put(2, 12, "Catalyst: " .. formatDescriptor(recipe.catalyst), COLORS.muted)
        local activationLP = self.catalog.activationLP or recipe.activationLP or 0
        local reserveLP = self.config.reserveLP or 0
        self:put(2, 13, "Meteor LP: " .. tostring(recipe.lp), COLORS.muted)
        self:put(2, 14, "Activation LP: " .. tostring(activationLP) .. "   Reserve LP: " .. tostring(reserveLP) .. "   Total LP budget: " .. tostring((recipe.lp or 0) + activationLP + reserveLP), COLORS.muted)
        local unsafe = recipe.safe_candidate == false or (recipe.ore_miner and recipe.ore_miner.safe_candidate == false)
        if unsafe then self:put(2, 15, "⚠ NON-ORE CANDIDATE — Ore Drilling Plants collect recognised ores; review outputs before cleanup.", COLORS.red) end
        self:put(2, 32, "Generated ore catalogue (weights; not output counts):", COLORS.cyan)
        local ores = recipe.ores or {}
        local page = math.floor((self.detailOrePage or 0) / 14)
        local first = page * 14 + 1
        for index = first, math.min(#ores, first + 13) do
          local ore = ores[index]
          local label = ore.label or ore.name or ore.key or "unknown ore"
          self:put(3, 32 + index - first + 1, tostring(label) .. "  weight=" .. tostring(ore.weight or "?"), COLORS.white)
        end
        self:put(3, 48, "Ores " .. #ores .. "   page " .. tostring(page + 1) .. "/" .. tostring(math.max(1, math.ceil(#ores / 14))) .. "   PgUp/PgDn browse", COLORS.muted)
      end
    end
  end

  function self:visibleHomeRows()
    local visible, filter = {}, (self.filters.home or ""):lower()
    for _, row in ipairs(self.view.rows or {}) do
      local label = formatDescriptor(row.product)
      if filter == "" or label:lower():find(filter, 1, true) then visible[#visible + 1] = row end
    end
    return visible
  end

  function self:activate()
    if self.screen == "confirm" then
      if self.selected == 1 then
        if self.confirmAction == "shutdown" then self:call("shutdown") else self:call("reset") end
      end
      self.confirmAction = nil; self:setScreen("home"); return
    end
    if self.screen == "home" then
      local rows = self:visibleHomeRows()
      local row = rows[self.selected]
      if row then self.policyKey = row.key; self:setScreen("policyedit") end
      return
    end
    local entries = self:entries()
    local entry = entries[self.selected]
    if entry and entry.action then entry.action() end
  end

  function self:removeMapping()
    if self.screen ~= "mapping" or not self.pendingOre then return end
    local products = self.config.oreProducts[self.pendingOre.key] or {}
    if #products == 0 then self.message = "No mapped product to remove."; return end
    local index = math.min(self.selected, #products)
    self:mutate(function()
      local nextProducts = copy(self.config.oreProducts[self.pendingOre.key] or {})
      table.remove(nextProducts, index)
      self.config.oreProducts[self.pendingOre.key] = #nextProducts > 0 and nextProducts or nil
    end)
    self:setScreen("mapping")
  end

  function self:keyEvent(event)
    local charCode, keyCode = event[3], event[4]
    if self.screen == "prompt" then
      if keyCode == KEY.esc then self:setScreen(self.prompt.priorScreen); return end
      if keyCode == KEY.enter then self:confirmPrompt(); return end
      if keyCode == KEY.backspace then
        local text = self.prompt.text
        self.prompt.text = size(text) > 0 and slice(text, 1, size(text) - 1) or ""
        return
      end
      if type(charCode) == "number" and charCode >= 32 and charCode ~= 127 then
        local okChar, character = pcall(unicode.char, charCode)
        if okChar then self.prompt.text = self.prompt.text .. character end
      end
      return
    end
    if self.screen == "confirm" then
      if keyCode == KEY.esc then self.confirmAction = nil; self:setScreen("home")
      elseif keyCode == KEY.left or keyCode == KEY.right then self.selected = self.selected == 1 and 2 or 1
      elseif keyCode == KEY.enter then self:activate() end
      return
    end
    if self.screen == "recipeDetail" and (keyCode == KEY.pageup or keyCode == KEY.pagedown) then
      local total = self.pendingRecipe and #(self.pendingRecipe.ores or {}) or 0
      local maxPage = math.max(0, (math.ceil(total / 14) - 1) * 14)
      self.detailOrePage = math.max(0, math.min(maxPage, (self.detailOrePage or 0) + (keyCode == KEY.pageup and -14 or 14)))
      return
    end
    if keyCode == KEY.esc then
      if self.screen == "home" then self:setScreen("menu")
      elseif self.screen == "menu" then self:setScreen("home")
      elseif self.screen == "mapping" then self:setScreen("ores")
      elseif self.screen == "browse" then self:setScreen("mapping")
      elseif self.screen == "policyedit" then self:setScreen("policies")
      elseif self.screen == "meteorChoices" then self:setScreen("policyedit")
      elseif self.screen == "recipeDetail" then self:setScreen("recipes")
      elseif self.screen == "addresses" then self:setScreen("hardware")
      else self:setScreen("menu") end
      return
    end
    if keyCode == KEY.up then self.selected = math.max(1, self.selected - 1)
    elseif keyCode == KEY.down then
      local count = self.screen == "home" and #self:visibleHomeRows() or #self:entries()
      self.selected = math.min(math.max(1, count), self.selected + 1)
    elseif keyCode == KEY.pageup then self.scroll = math.max(0, self.scroll - PAGE_SIZE); self.selected = math.max(1, self.selected - PAGE_SIZE)
    elseif keyCode == KEY.pagedown then self.scroll = self.scroll + PAGE_SIZE; self.selected = self.selected + PAGE_SIZE
    elseif keyCode == KEY.home then self.selected, self.scroll = 1, 0
    elseif keyCode == KEY.finish then
      local count = self.screen == "home" and #self:visibleHomeRows() or #self:entries()
      self.selected = math.max(1, count)
    elseif keyCode == KEY.enter then self:activate()
    elseif keyCode == KEY.backspace and self.filters[self.screen] then
      local key = self.screen; self.filters[key] = slice(self.filters[key], 1, size(self.filters[key]) - 1); self.selected, self.scroll = 1, 0
    elseif charCode == 47 and ({home = true, ores = true, browse = true, policies = true, recipes = true})[self.screen] then
      local keys = {home = "home", ores = "ores", browse = "browse", policies = "policies", recipes = "recipes"}
      self:openPrompt("filter", keys[self.screen], self.filters[keys[self.screen]] or "", "text")
    elseif charCode == 109 and self.screen == "home" then self:setScreen("menu")
    elseif charCode == 97 and self.screen == "home" then self:call("auto")
    elseif charCode == 115 and self.screen == "home" then self:call("stop")
    elseif charCode == 113 and self.screen == "home" then self.confirmAction = "shutdown"; self:setScreen("confirm")
    elseif charCode == 118 and self.screen == "home" then self:setScreen("machines")
    elseif (charCode == 100 or charCode == 127) and self.screen == "mapping" then self:removeMapping()
    elseif charCode == 97 and self.screen == "mapping" then self:beginBrowse("item") end
    local count = self.screen == "home" and #self:visibleHomeRows() or #self:entries()
    if count > 0 then
      self.selected = math.max(1, math.min(count, self.selected))
      self.scroll = math.floor((self.selected - 1) / PAGE_SIZE) * PAGE_SIZE
    else
      self.selected, self.scroll = 1, 0
    end
  end

  function self:clipboardEvent(event)
    if self.screen == "prompt" and type(event[3]) == "string" then self.prompt.text = self.prompt.text .. event[3] end
  end

  function self:touchEvent(event)
    local x, y = tonumber(event[3]), tonumber(event[4])
    if not x or not y then return end
    if self.screen == "home" then
      if y == 41 then
        if x < 15 then self:setScreen("menu") elseif x < 33 then self:call("auto") elseif x < 45 then self:call("stop") else self.confirmAction = "shutdown"; self:setScreen("confirm") end
      elseif y >= 9 and y <= 26 then
        self.selected = math.max(1, y - 8 + math.floor(self.scroll / 18) * 18)
        self:activate()
      end
      return
    end
    if self.screen == "prompt" then
      if y >= 9 and x > 2 then self:confirmPrompt() end
      return
    end
    if self.screen == "confirm" then
      self.selected = x < 20 and 1 or 2
      self:activate(); return
    end
    local offset = ({ores = true, browse = true, policies = true, recipes = true, recipeDetail = true})[self.screen] and 6 or 5
    if y >= offset and y < offset + PAGE_SIZE then
      local index = math.floor(self.scroll / PAGE_SIZE) * PAGE_SIZE + y - offset + 1
      local entries = self:entries()
      if entries[index] then self.selected = index; self:activate() end
    end
  end

  function self:handle(event)
    if self.closed or type(event) ~= "table" then return end
    local name = event[1]
    if name == "key_down" then self:keyEvent(event)
    elseif name == "clipboard" then self:clipboardEvent(event)
    elseif name == "touch" then self:touchEvent(event)
    elseif name == "scroll" then
      local direction = tonumber(event[5]) or 0
      if self.screen == "recipeDetail" then
        local total = self.pendingRecipe and #(self.pendingRecipe.ores or {}) or 0
        local maxPage = math.max(0, (math.ceil(total / 14) - 1) * 14)
        self.detailOrePage = math.max(0, math.min(maxPage, (self.detailOrePage or 0) + (direction > 0 and -14 or 14)))
      else
        local count = self.screen == "home" and #self:visibleHomeRows() or #self:entries()
        self.selected = direction > 0 and math.max(1, self.selected - 1) or math.min(math.max(1, count), self.selected + 1)
        self.scroll = math.floor((self.selected - 1) / PAGE_SIZE) * PAGE_SIZE
      end
    end
    self:draw()
  end

  function self:close()
    if self.closed then return end
    self.closed = true
    pcall(self.gpu.setResolution, self.oldResolution[1], self.oldResolution[2])
    if self.oldForeground then pcall(self.gpu.setForeground, self.oldForeground[1], self.oldForeground[2]) end
    if self.oldBackground then pcall(self.gpu.setBackground, self.oldBackground[1], self.oldBackground[2]) end
    if self.oldDepth then pcall(self.gpu.setDepth, self.oldDepth) end
  end

  return self
end

return M
