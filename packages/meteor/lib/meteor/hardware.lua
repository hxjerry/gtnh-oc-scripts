local identity = require("meteor.identity")
local M, Hardware = {}, {}
Hardware.__index = Hardware
local function callable(method)
  local mt = type(method) == "table" and getmetatable(method)
  return type(method) == "function" or (type(mt) == "table" and type(mt.__call) == "function")
end
local function need(proxy, methods, label)
  for _, name in ipairs(methods) do
    -- OC component.proxy exposes methods as tables with a callable metatable.
    assert(callable(proxy[name]),
      label .. " lacks " .. name)
  end
  return proxy
end
local function number(value, label)
  assert(type(value) == "number" and value == value and value >= 0 and value < math.huge, "Invalid " .. label)
  return value
end
local function readSlot(transposer, side, slot)
  local stack, err = transposer.getStackInSlot(side, slot)
  assert(err == nil, "Inventory read failed: " .. tostring(err))
  if not stack then return nil end
  if number(stack.size, "stack size") == 0 then return nil end
  return stack
end
local function inventorySize(transposer, side)
  local size, err = transposer.getInventorySize(side)
  assert(err == nil, "Inventory size read failed: " .. tostring(err))
  size = number(size, "inventory size")
  assert(size > 0 and size % 1 == 0, "Missing inventory on side " .. side)
  return size
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
  self.me = need(proxy(h.me, "me_interface"), {"getItemInNetwork", "getFluidInNetwork", "getCraftable", "setInterfaceConfiguration", "getInterfaceConfiguration"}, "Block ME interface")
  self.transposer = need(proxy(h.transposer, "transposer"), {"getStackInSlot", "getInventorySize", "getFluidInContainerInSlot", "transferItem"}, "Transposer")
  local sourceSize = inventorySize(self.transposer, h.sourceSide)
  local orbSize = inventorySize(self.transposer, h.orbSide)
  local outputSize = inventorySize(self.transposer, h.outputSide)
  assert(h.orbSlot <= orbSize, "Orb slot outside inventory")
  assert(math.max(h.focusSlot, h.catalystSlot) <= outputSize, "Drop slots outside inventory")
  assert(h.interfaceSlot <= sourceSize, "ME source slot outside inventory")
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
function Hardware:sampleProduct(side, slot)
  assert(type(side) == "number" and side == side and side % 1 == 0 and side >= 0 and side <= 5,
    "Invalid transposer side")
  assert(type(slot) == "number" and slot == slot and slot % 1 == 0 and slot >= 1 and slot < math.huge,
    "Invalid transposer slot")
  local address = self.config.hardware.transposer
  assert(type(address) == "string" and address ~= "", "Configure transposer address in Setup")
  assert(self.component.type(address) == "transposer", "Missing transposer: " .. address)
  local transposer = need(self.component.proxy(address),
    {"getStackInSlot", "getInventorySize", "getFluidInContainerInSlot"}, "Transposer")
  local size = inventorySize(transposer, side)
  assert(slot <= size, "Sample slot outside inventory")
  local stack = readSlot(transposer, side, slot)
  assert(stack, "Sample slot is empty")
  local fluid, fluidError = transposer.getFluidInContainerInSlot(side, slot)
  if fluid ~= nil then
    assert(fluidError == nil, "Container inspection failed: " .. tostring(fluidError))
    return identity.fromStack(fluid, "fluid")
  end
  assert(fluidError == nil or fluidError == "item is not a fluid container",
    "Container inspection failed: " .. tostring(fluidError))
  return identity.fromStack(stack, "item")
end
function Hardware:stock(rows)
  local counts = {}
  for _, row in ipairs(rows) do
    local product = row.product
    local stack, reason
    if product.kind == "fluid" then stack, reason = self.me.getFluidInNetwork(identity.filter(product))
    else stack, reason = self.me.getItemInNetwork(identity.filter(product)) end
    assert(reason == nil, "ME stock read failed: " .. tostring(reason))
    counts[row.key] = 0
    if stack then
      assert(identity.same(identity.fromStack(stack, product.kind), product), "ME returned a different product")
      counts[row.key] = number(product.kind == "fluid" and stack.amount or stack.size, "ME quantity")
    end
  end
  return counts
end
function Hardware:inputCount(descriptor)
  local stack, reason = self.me.getItemInNetwork(identity.filter(descriptor))
  assert(reason == nil, "ME input read failed: " .. tostring(reason))
  if not stack then return 0 end
  assert(identity.same(identity.fromStack(stack), descriptor), "ME returned a different input")
  return number(stack.size, "input stock")
end
function Hardware:request(descriptor, amount)
  assert(type(amount) == "number" and amount > 0 and amount < math.huge and amount % 1 == 0, "Invalid craft amount")
  local craftable, reason = self.me.getCraftable(identity.filter(descriptor), "item")
  assert(reason == nil, "Craftable lookup failed: " .. tostring(reason))
  assert(craftable, "No exact autocrafting pattern for " .. identity.describe(descriptor))
  need(craftable, {"getStack", "request"}, "Craftable")
  local stack = craftable.getStack()
  assert(stack and identity.same(identity.fromStack(stack), descriptor), "Craftable returned a different input")
  local job, err = craftable.request(amount)
  assert(job, "Craft request failed: " .. tostring(err))
  return job
end
function Hardware:craftStatus(job)
  local ok, status, reason = pcall(function()
    need(job, {"isCanceled", "isDone", "hasFailed"}, "Crafting status")
    local canceled, why = job.isCanceled()
    assert(type(canceled) == "boolean", "Invalid craft cancellation status")
    if canceled then
      local failed, failure = job.hasFailed()
      assert(type(failed) == "boolean", "Invalid craft failure status")
      if failed and failure == "no link" then return nil, failure end
      return failed and "failed" or "canceled", failure or why
    end
    local done, detail = job.isDone()
    assert(type(done) == "boolean", "Invalid craft completion status")
    if detail == "no link" then return nil, detail end
    return done and "done" or "active", detail
  end)
  if not ok then return nil, status end
  return status, reason
end
function Hardware:crafting(descriptor)
  local ok, active, reason = pcall(function()
    need(self.me, {"getCpus"}, "Block ME interface")
    local cpus, err = self.me.getCpus()
    assert(err == nil and type(cpus) == "table", "Cannot inspect crafting CPUs: " .. tostring(err))
    local unknown
    for _, entry in pairs(cpus) do
      assert(type(entry.busy) == "boolean", "Invalid crafting CPU state")
      if entry.busy then
        local observed, output = pcall(function()
          need(entry.cpu, {"finalOutput"}, "Crafting CPU")
          local stack, why = entry.cpu.finalOutput()
          assert(stack, "Cannot inspect crafting output: " .. tostring(why))
          return identity.fromStack(stack)
        end)
        if observed then
          if identity.same(output, descriptor) then return true end
        else unknown = tostring(output) end
      end
    end
    if unknown then return nil, unknown end
    return false
  end)
  if not ok then return nil, active end
  return active, reason
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
function Hardware:stageSlots(count)
  local h, slots = self.config.hardware, {}
  local size = inventorySize(self.transposer, h.orbSide)
  for slot = 1, size do
    if slot ~= h.orbSlot and not readSlot(self.transposer, h.orbSide, slot) then
      slots[#slots + 1] = slot
      if #slots == count then return slots end
    end
  end
  return nil, "Need " .. count .. " empty orb-inventory slots (excluding the orb)"
end
function Hardware:stageInput(descriptor, slot)
  local h = self.config.hardware
  assert(slot ~= h.orbSlot and slot >= 1 and slot <= inventorySize(self.transposer, h.orbSide), "Invalid buffer slot")
  assert(not readSlot(self.transposer, h.orbSide, slot), "Orb buffer slot must be empty before staging")
  local stack = readSlot(self.transposer, h.sourceSide, h.interfaceSlot)
  if not stack then return false end
  assert(identity.same(identity.fromStack(stack), descriptor), "Wrong metadata/NBT in ME staging slot")
  local moved, why = self.transposer.transferItem(h.sourceSide, h.orbSide, 1, h.interfaceSlot, slot)
  assert(why == nil and (moved == 0 or moved == 1), "Staging transfer failed: " .. tostring(why))
  if moved == 1 then self:clearInput(); return true end
  return false
end
function Hardware:verifyStaged(inputs)
  local h = self.config.hardware
  for _, input in ipairs(inputs) do
    assert(input.slot ~= h.orbSlot, "Cannot use blood orb slot as buffer")
    local stack = readSlot(self.transposer, h.orbSide, input.slot)
    if not stack then return false end
    assert(stack.size == 1 and identity.same(identity.fromStack(stack), input.descriptor),
      "Buffered input changed: " .. input.role)
  end
  return true
end
function Hardware:deliverInput(descriptor, stagedSlot, dropSlot)
  local h = self.config.hardware
  if not self:verifyStaged({{descriptor = descriptor, slot = stagedSlot, role = descriptor.name}}) then return false end
  assert(not readSlot(self.transposer, h.outputSide, dropSlot), "Drop slot must be empty before transfer")
  local moved, why = self.transposer.transferItem(h.orbSide, h.outputSide, 1, stagedSlot, dropSlot)
  assert(why == nil and (moved == 0 or moved == 1), "Delivery transfer failed: " .. tostring(why))
  return moved == 1
end
function Hardware:returnInput(descriptor, stagedSlot)
  local h = self.config.hardware
  assert(not self.ownsSlot, "Clear ME reservation before returning inputs")
  if not self:verifyStaged({{descriptor = descriptor, slot = stagedSlot, role = descriptor.name}}) then return true end
  local destination = readSlot(self.transposer, h.sourceSide, h.interfaceSlot)
  if destination and not identity.same(identity.fromStack(destination), descriptor) then return false end
  local moved, why = self.transposer.transferItem(h.orbSide, h.sourceSide, 1, stagedSlot, h.interfaceSlot)
  assert(why == nil and (moved == 0 or moved == 1), "Return transfer failed: " .. tostring(why))
  return moved == 1
end
function Hardware:checkStageEmpty(record)
  assert(type(record) == "table" and type(record.transposer) == "string" and record.transposer ~= ""
    and type(record.side) == "number" and record.side >= 0 and record.side <= 5 and record.side % 1 == 0
    and type(record.slots) == "table" and #record.slots > 0, "Invalid staging journal; inspect buffered inputs")
  assert(self.component.type(record.transposer) == "transposer", "Reconnect original staging transposer for recovery")
  local transposer = need(self.component.proxy(record.transposer), {"getInventorySize", "getStackInSlot"}, "Staging transposer")
  local size = inventorySize(transposer, record.side)
  for _, slot in ipairs(record.slots) do
    assert(type(slot) == "number" and slot >= 1 and slot <= size and slot % 1 == 0, "Invalid journal buffer slot")
    assert(not readSlot(transposer, record.side, slot), "Empty recorded orb buffer slot " .. slot .. " before recovery")
  end
  return true
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
