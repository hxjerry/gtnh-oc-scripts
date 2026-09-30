local identity = require("meteor.identity")
local M, Hardware = {}, {}
Hardware.__index = Hardware
local function need(proxy, methods, label)
  for _, name in ipairs(methods) do
    assert(type(proxy[name]) == "function", label .. " lacks " .. name)
  end
  return proxy
end
local function number(value, label)
  assert(type(value) == "number" and value == value and value >= 0 and value < math.huge, "Invalid " .. label)
  return value
end
local function isPlant(name)
  -- Registered Ore Drilling Plant I-IV family; no other GT machine is controlled.
  return type(name) == "string" and name:match("^multimachine%.oredrill[1-4]$") ~= nil
end
function M.new(component, config)
  return setmetatable({component = component, config = config, plants = {}, ownsSlot = false}, Hardware)
end
function Hardware:discover()
  local result = {me = {}, transposer = {}, redstone = {}, plants = {}}
  for address, kind in self.component.list() do
    if kind == "me_interface" then result.me[#result.me + 1] = address
    elseif kind == "transposer" then result.transposer[#result.transposer + 1] = address
    elseif kind == "redstone" then result.redstone[#result.redstone + 1] = address
    elseif kind == "gt_machine" then
      local proxy = self.component.proxy(address)
      if proxy.getName and isPlant(proxy.getName()) then result.plants[#result.plants + 1] = address end
    end
  end
  for _, values in pairs(result) do table.sort(values) end
  return result
end
function Hardware:connect()
  local h = self.config.hardware
  self.boundHardware = {}
  for k, v in pairs(h) do self.boundHardware[k] = v end
  local function proxy(address, kind)
    assert(type(address) == "string" and address ~= "", "Configure " .. kind .. " address in Setup")
    assert(self.component.type(address) == kind, "Missing " .. kind .. ": " .. address)
    return self.component.proxy(address)
  end
  self.ritual = need(proxy(h.ritual, "redstone"), {"setOutput"}, "Ritual redstone")
  self.ritual.setOutput(h.ritualSide, 0)
  self.filler = need(proxy(h.filler, "redstone"), {"setOutput", "getInput"}, "Filler redstone")
  self.filler.setOutput(h.fillerOutSide, 0)
  self.me = need(proxy(h.me, "me_interface"), {"getItemsInNetwork", "getFluidsInNetwork", "getCraftables", "setInterfaceConfiguration", "getInterfaceConfiguration"}, "Block ME interface")
  self.transposer = need(proxy(h.transposer, "transposer"), {"getStackInSlot", "getInventorySize", "transferItem"}, "Transposer")
  for _, side in ipairs({h.sourceSide, h.orbSide, h.outputSide}) do
    assert(number(self.transposer.getInventorySize(side), "inventory size") > 0, "Missing inventory on side " .. side)
  end
  assert(h.orbSlot <= self.transposer.getInventorySize(h.orbSide), "Orb slot outside inventory")
  assert(math.max(h.focusSlot, h.catalystSlot) <= self.transposer.getInventorySize(h.outputSide), "Drop slots outside inventory")
  assert(h.interfaceSlot <= self.transposer.getInventorySize(h.sourceSide), "ME source slot outside inventory")
  self.plants = {}
  for _, address in ipairs(self:discover().plants) do
    local p = need(self.component.proxy(address), {"getName", "setWorkAllowed", "isWorkAllowed", "hasWork", "isMachineActive", "getWorkProgress", "getWorkMaxProgress"}, "Ore Drilling Plant " .. address)
    self.plants[#self.plants + 1] = {address = address, proxy = p, status = "discovered"}
  end
  return self
end
function Hardware:safe()
  -- Attempt every shutdown even if one component vanished. Do not hide failures.
  local errors = {}
  local function attempt(label, fn)
    local ok, err = pcall(fn)
    if not ok then errors[#errors + 1] = label .. ": " .. tostring(err) end
  end
  local h = self.boundHardware or self.config.hardware
  if self.ritual then attempt("ritual", function() self.ritual.setOutput(h.ritualSide, 0) end) end
  if self.filler then attempt("filler", function() self.filler.setOutput(h.fillerOutSide, 0) end) end
  for _, plant in ipairs(self.plants) do
    attempt(plant.address, function() plant.proxy.setWorkAllowed(false) end)
  end
  if self.ownsSlot and self.me then
    attempt("ME reservation", function()
      assert(self.me.setInterfaceConfiguration(h.interfaceSlot), "Could not clear reservation")
      self.ownsSlot = false
    end)
  end
  return #errors == 0, table.concat(errors, "; ")
end
function Hardware:network(kind)
  assert(self.me, "Configure and connect hardware first")
  local values, reason
  if kind == "fluid" then values, reason = self.me.getFluidsInNetwork()
  else values, reason = self.me.getItemsInNetwork() end
  assert(type(values) == "table", "ME read failed: " .. tostring(reason))
  return values
end
function Hardware:catalogue(kind)
  local values, skipped = {}, {}
  for _, stack in pairs(self:network(kind)) do
    local ok, descriptor = pcall(identity.fromStack, stack, kind)
    if ok then values[#values + 1] = descriptor
    else skipped[#skipped + 1] = tostring(descriptor) end
  end
  table.sort(values, function(a, b)
    return a.label == b.label and identity.key(a) < identity.key(b) or a.label < b.label
  end)
  return values, skipped
end
function Hardware:stock(rows)
  local required, counts, kinds = {}, {}, {}
  for _, row in ipairs(rows) do
    required[row.product.kind .. "\0" .. row.product.name] = true
    counts[row.key] = 0
    kinds[row.product.kind] = true
  end
  for kind in pairs(kinds) do
    for _, stack in pairs(self:network(kind)) do
      if required[kind .. "\0" .. tostring(stack.name)] then
        -- Unknown NBT in a monitored registry family invalidates the snapshot.
        local key = identity.key(identity.fromStack(stack, kind))
        if counts[key] ~= nil then
          counts[key] = counts[key] + number(kind == "fluid" and stack.amount or stack.size, "ME quantity")
        end
      end
    end
  end
  return counts
end
function Hardware:inputCount(descriptor)
  local values, reason = self.me.getItemsInNetwork(identity.filter(descriptor))
  assert(type(values) == "table", "ME input read failed: " .. tostring(reason))
  local count = 0
  for _, stack in pairs(values) do
    if identity.same(identity.fromStack(stack), descriptor) then count = count + number(stack.size, "input stock") end
  end
  return count
end
function Hardware:request(descriptor)
  local values, reason = self.me.getCraftables(identity.filter(descriptor))
  assert(type(values) == "table", "Craftable lookup failed: " .. tostring(reason))
  local match
  for _, craftable in pairs(values) do
    local stack = craftable.getStack()
    if stack and identity.same(identity.fromStack(stack), descriptor) then
      assert(not match, "Ambiguous exact crafting pattern for " .. descriptor.name)
      match = craftable
    end
  end
  assert(match, "No exact autocrafting pattern for " .. identity.describe(descriptor))
  local job, err = match.request(1)
  assert(job, "Craft request failed: " .. tostring(err))
  return job
end
function Hardware:readLP()
  local h = self.config.hardware
  assert(h.owner ~= "", "Configure the ritual owner's exact name")
  local orb, err = self.transposer.getStackInSlot(h.orbSide, h.orbSlot)
  assert(type(orb) == "table", "Missing blood orb: " .. tostring(err))
  assert(orb.ownerName == h.owner, "Blood orb owner does not match configured ritual owner")
  assert(type(orb.orbTier) == "number" and orb.orbTier > 0, "Stack is not an inspectable bound blood orb")
  return number(orb.networkEssence, "live blood orb networkEssence")
end
function Hardware:emptyOutput()
  local h = self.config.hardware
  for _, slot in ipairs({h.focusSlot, h.catalystSlot}) do
    local stack, err = self.transposer.getStackInSlot(h.outputSide, slot)
    assert(err == nil, "Cannot inspect output slot: " .. tostring(err))
    if stack and (stack.size or 0) > 0 then return false end
  end
  return true
end
function Hardware:reserveInput(descriptor)
  local h = self.config.hardware
  local existing, err = self.me.getInterfaceConfiguration(h.interfaceSlot)
  assert(err == nil, "Cannot inspect ME reservation: " .. tostring(err))
  assert(not existing or (existing.size or 0) == 0, "Reserved ME interface slot is already configured")
  -- Mark ownership before a potentially non-atomic callback.
  self.ownsSlot = true
  assert(self.me.setInterfaceConfiguration(h.interfaceSlot, identity.detail(descriptor, 1)), "ME interface rejected reservation")
end
function Hardware:clearInput()
  assert(self.me.setInterfaceConfiguration(self.config.hardware.interfaceSlot), "Could not clear ME interface reservation")
  self.ownsSlot = false
end
function Hardware:recoverInput()
  -- Setup dedicates this one configuration slot to meteor; all other slots are untouched.
  self.ownsSlot = true
  self:clearInput()
end
function Hardware:transferInput(descriptor, slot)
  local h = self.config.hardware
  local stack, err = self.transposer.getStackInSlot(h.sourceSide, h.interfaceSlot)
  assert(err == nil, "ME source read failed: " .. tostring(err))
  if not stack or (stack.size or 0) == 0 then return false end
  assert(identity.same(identity.fromStack(stack), descriptor), "Wrong metadata/NBT in ME staging slot")
  local destination, destError = self.transposer.getStackInSlot(h.outputSide, slot)
  assert(destError == nil, "Drop inventory read failed: " .. tostring(destError))
  assert(not destination or (destination.size or 0) == 0, "Drop slot must be empty before transfer")
  local moved, why = self.transposer.transferItem(h.sourceSide, h.outputSide, 1, h.interfaceSlot, slot)
  assert(type(moved) == "number", "Transfer failed: " .. tostring(why))
  assert(moved == 0 or moved == 1, "Unexpected transfer count")
  if moved == 1 then self:clearInput(); return true end
  return false
end
function Hardware:ritualOutput(enabled)
  self.ritual.setOutput(self.config.hardware.ritualSide, enabled and 15 or 0)
end
function Hardware:fillerOutput(enabled)
  self.filler.setOutput(self.config.hardware.fillerOutSide, enabled and 15 or 0)
end
function Hardware:fillerNoWork()
  return number(self.filler.getInput(self.config.hardware.fillerInSide), "filler no-work signal") > 0
end
function Hardware:preparePlants()
  assert(#self.plants > 0, "No Ore Drilling Plants found (connect adapters to plant controllers)")
  for _, plant in ipairs(self.plants) do
    assert(not plant.proxy.isWorkAllowed() and not plant.proxy.isMachineActive() and not plant.proxy.hasWork(),
      "Ore Drilling Plant must be stopped before a cycle: " .. plant.address)
    plant.seenWork, plant.done, plant.status = false, false, "ready"
  end
end
function Hardware:startPlants()
  for _, plant in ipairs(self.plants) do
    plant.proxy.setWorkAllowed(true)
    assert(plant.proxy.isWorkAllowed(), "Ore Drilling Plant rejected start: " .. plant.address)
    plant.status = "starting"
  end
end
function Hardware:pollPlants()
  local current = self:discover().plants
  assert(#current == #self.plants, "Ore Drilling Plant topology changed during cycle")
  local complete = true
  for i, plant in ipairs(self.plants) do
    assert(current[i] == plant.address, "Ore Drilling Plant disconnected/replaced during cycle")
    local allowed, active, work = plant.proxy.isWorkAllowed(), plant.proxy.isMachineActive(), plant.proxy.hasWork()
    assert(type(allowed) == "boolean" and type(active) == "boolean" and type(work) == "boolean", "Invalid plant status")
    local maximum = number(plant.proxy.getWorkMaxProgress(), "plant maximum progress")
    local progress = number(plant.proxy.getWorkProgress(), "plant progress")
    if active and work and maximum > 0 then plant.seenWork = true end
    local stopped = not allowed and not active and not work
    assert(not stopped or plant.seenWork, "Ore Drilling Plant stopped before observed work: " .. plant.address)
    -- MTEDrillerBase normally disables only after UPWARD pipe retraction.
    -- Stock OC callbacks expose no shutdown reason; power/maintenance shutdowns
    -- after activity are indistinguishable. See the commissioning contract.
    plant.done = stopped and plant.seenWork
    plant.status = plant.done and "stopped after work" or
      (active and work and ("working / retracting: " .. progress .. "/" .. maximum) or
        (allowed and "waiting: power / fluid / pipes / output" or "stopping"))
    complete = complete and plant.done
  end
  return complete
end
return M
