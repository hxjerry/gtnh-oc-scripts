local model = require("meteor.model")
local identity = require("meteor.identity")
local M, Controller = {}, {}
Controller.__index = Controller
local CATALYST_SECONDS, PULSE_SECONDS = 30, 0.25
function M.new(config, catalog, hardware, clock, journal)
  return setmetatable({config = config, catalog = catalog, hw = hardware, clock = clock,
    journal = journal, state = "IDLE", mode = "stopped", logs = {}, rows = {}, detail = "Configure hardware, map products, then select a mode",
    nextStock = 0, nextPlant = 0, nextCycle = 0, nextPrepare = 0, requests = {},
    unknownCraftUntil = clock() + config.craftTimeout}, Controller)
end
function Controller:log(text)
  self.logs[#self.logs + 1] = string.format("%8.1f  %s", self.clock(), tostring(text))
  if #self.logs > 80 then table.remove(self.logs, 1) end
end
function Controller:transition(state, detail)
  self.state, self.since, self.detail = state, self.clock(), detail or state
  self:log(self.detail)
end
function Controller:fault(reason)
  self.mode, self.lastError = "stopped", tostring(reason)
  local ok, err = self.hw:safe()
  if not ok then self.lastError = self.lastError .. "; safe-off FAILED: " .. err end
  self:transition("FAULT", self.lastError)
end
function Controller:boot(interrupted, stageRecord)
  if interrupted then self.stageRecord = stageRecord end
  local ok, err = self.hw:safe()
  if interrupted then self:fault("Interrupted cycle: inspect site and acknowledge Recovery; never replaying ritual")
  elseif not ok then self:fault(err) end
end
function Controller:reset()
  assert(self.state == "FAULT" or self.state == "IDLE", "Stop before recovery")
  local ok, err = self.hw:safe()
  assert(ok, err)
  self.hw:recoverInput()
  assert(self.hw:emptyOutput(), "Empty both drop slots before recovery")
  if self.stageRecord then self.hw:checkStageEmpty(self.stageRecord) end
  self.hw:preparePlants()
  self.hw:readLP()
  self.journal(false)
  self.recipe, self.input, self.lastError, self.mode = nil, nil, nil, "stopped"
  self.pending, self.inputs, self.stageRecord = nil, nil, nil
  self:transition("IDLE", "Recovery acknowledged; site clear, MRS inactive, Ore Drilling Plants stopped")
end
function Controller:stop()
  self.mode = "stopped"
  if self.state ~= "IDLE" and self.state ~= "FAULT" then
    self:fault("Operator stopped cycle; recover physical site before restarting")
  else
    local ok, err = self.hw:safe()
    if not ok then self:fault(err) end
    if self.state == "IDLE" then self.detail = "Stopped; outstanding ME crafts are not canceled" end
  end
end
function Controller:auto()
  assert(self.state == "IDLE", "Recover before starting automation")
  model.validate(self.config, self.catalog)
  self.mode, self.nextCycle, self.nextStock, self.nextPrepare = "auto", self.clock(), 0, 0
  self:log("Stock automation enabled")
end
function Controller:run(id, loop)
  assert(self.state == "IDLE", "Another task is running or recovery is required")
  model.recipe(self.catalog, id)
  self.manualRecipe, self.mode = id, loop and "loop" or "once"
  self.nextCycle, self.nextPrepare = self.clock(), self.clock() + 1
  self:prepare(id, self.config.manualCraft)
end
function Controller:refresh()
  self.rows = model.aggregate(self.config, self.catalog)
  local counts = self.hw:stock(self.rows)
  for _, row in ipairs(self.rows) do row.stock = counts[row.key] end
  self.nextStock = self.clock() + 5
end
function Controller:requestKey(descriptor)
  return self.config.hardware.me .. "\0" .. identity.key(descriptor)
end
function Controller:observeRequest(descriptor, count)
  local key = self:requestKey(descriptor)
  local request = self.requests[key]
  if not request then return end
  if request.job then
    local status, reason = self.hw:craftStatus(request.job)
    if (status == "failed" or status == "canceled") and status ~= request.status then
      self:log("Autocraft " .. status .. ": " .. descriptor.name .. "; " .. tostring(reason))
    end
    request.status = status
    if status == "failed" or status == "canceled" then request.job = nil end
  end
  if request.status == "done" and count > 0 then
    self.requests[key] = nil
    return
  end
  return request
end
function Controller:ensureCraft(descriptor, amount, request)
  local now, key = self.clock(), self:requestKey(descriptor)
  -- A live computing/link status wins over elapsed time and save-tainted hasFailed.
  if request and request.status == "active" then return end
  local crafting = self.hw:crafting(descriptor)
  if crafting then
    request = request or {}
    request.observedAt = now
    self.requests[key] = request
    return
  end
  local retryAt = request and request.attemptAt and request.attemptAt + self.config.craftTimeout or 0
  if crafting == nil then
    retryAt = math.max(retryAt, request and request.observedAt
      and request.observedAt + self.config.craftTimeout or self.unknownCraftUntil)
  end
  if now < retryAt then return end
  -- Record the attempt before calling ME: a callback error may follow submission.
  request = {attemptAt = now}
  self.requests[key] = request
  local ok, job = pcall(self.hw.request, self.hw, descriptor, amount)
  if ok and job then
    request.job = job
    self:log("Requested " .. amount .. " exact " .. descriptor.name .. " via ME autocrafting")
  else
    self:log("Autocraft unavailable: " .. descriptor.name .. "; " .. tostring(job))
  end
end
function Controller:prepare(id, craft)
  local recipe = model.recipe(self.catalog, id)
  local inputs = {}
  if self.config.useCatalyst then inputs[#inputs + 1] = {descriptor = recipe.catalyst, role = "catalyst"} end
  inputs[#inputs + 1] = {descriptor = recipe.focus, role = "focus"}
  local needs, order = {}, {}
  for _, input in ipairs(inputs) do
    local key = identity.key(input.descriptor)
    if not needs[key] then
      needs[key] = {descriptor = input.descriptor, amount = 0}
      order[#order + 1] = needs[key]
    end
    needs[key].amount = needs[key].amount + 1
  end
  local ready = true
  for _, need in ipairs(order) do
    local observed, count = pcall(self.hw.inputCount, self.hw, need.descriptor)
    if not observed then
      ready = false
      self:log("Input observation deferred: " .. need.descriptor.name .. "; " .. tostring(count))
    else
      local request = self:observeRequest(need.descriptor, count)
      if count < need.amount then
        ready = false
        if craft then self:ensureCraft(need.descriptor, need.amount - count, request) end
      end
    end
  end
  if not ready then
    self.detail = recipe.label .. ": inputs absent; " .. (craft and "crafts pending or retry deferred" or "autocrafting disabled")
    return false
  end
  local slots, why = self.hw:stageSlots(#inputs)
  if not slots then self.detail = recipe.label .. ": " .. tostring(why); return false end
  assert(self.hw:emptyOutput(), "Drop inventory not empty; refusing another focus")
  self.lp = self.hw:readLP()
  self.hw:preparePlants()
  for i, input in ipairs(inputs) do input.slot = slots[i] end
  self.stageRecord = {transposer = self.hw.transposer.address, side = self.config.hardware.orbSide, slots = slots}
  -- Only physical staging/ritual work dirties the journal; background crafts do not.
  self.journal(true, self.stageRecord)
  self.pending = {recipe = recipe, inputs = inputs, index = 1}
  self.consuming = false
  self:transition("STAGING", "Buffering all inputs in orb inventory: " .. recipe.label)
  return true
end
function Controller:stageTick()
  local pending, now = self.pending, self.clock()
  local input = pending.inputs[pending.index]
  if not input.started then input.started = now end
  local observed, count = pcall(self.hw.inputCount, self.hw, input.descriptor)
  if not observed or count < 1 or now - input.started >= self.config.inputTimeout then
    self:beginReturn("Staging input unavailable; yielding without starting ritual")
    return
  end
  if not input.reserved then
    local ok, err = pcall(self.hw.reserveInput, self.hw, input.descriptor)
    if not ok then
      self:beginReturn("ME reservation deferred: " .. tostring(err))
      return
    end
    input.reserved = true
  end
  if not self.hw:stageInput(input.descriptor, input.slot) then return end
  input.staged = true
  pending.index = pending.index + 1
  if pending.index <= #pending.inputs then return end
  if not self.hw:verifyStaged(pending.inputs) then
    self:beginReturn("Buffered input taken; yielding without starting ritual")
    return
  end
  self.recipe, self.inputs, self.pending = pending.recipe, pending.inputs, nil
  self.requiredLP = self.recipe.lp + self.catalog.activationLP + self.config.reserveLP
  self:transition("LP", "All inputs buffered; waiting for " .. self.requiredLP .. " LP: " .. self.recipe.label)
end
function Controller:beginReturn(reason)
  self.pending = self.pending or {recipe = self.recipe, inputs = self.inputs}
  self.recipe, self.inputs, self.input = nil, nil, nil
  self.pending.index = 1
  self:transition("RETURNING", reason)
end
function Controller:returnTick()
  local pending = self.pending
  if not pending.cleared then
    local ok, err = pcall(self.hw.clearInput, self.hw)
    if not ok then self.detail = "Waiting to clear ME reservation: " .. tostring(err); return end
    pending.cleared = true
  end
  local input = pending.inputs[pending.index]
  if input.staged and not self.hw:returnInput(input.descriptor, input.slot) then
    self.detail = "Waiting for ME interface space to return buffered " .. input.role
    return
  end
  pending.index = pending.index + 1
  if pending.index <= #pending.inputs then return end
  self.journal(false)
  self.pending, self.stageRecord = nil, nil
  self.nextPrepare = self.clock() + 1
  self:transition("IDLE", "Inputs released; selecting another deficit")
end
function Controller:lpReady()
  self.lp = self.hw:readLP()
  if self.lp < self.requiredLP then
    self.detail = "LP " .. self.lp .. " / " .. self.requiredLP .. "; ritual inhibited"
    return false
  end
  return true
end
function Controller:beginInput(role)
  for _, input in ipairs(self.inputs) do
    if input.role == role then
      self.input, input.started = input, self.clock()
      self:transition("INPUT", "Delivering buffered " .. role .. ": " .. input.descriptor.name)
      return
    end
  end
  error("Missing buffered " .. role)
end
function Controller:inputTick()
  local input, now = self.input, self.clock()
  assert(now - input.started < self.config.inputTimeout, "Input timed out: " .. input.descriptor.name)
  if not self.hw:verifyStaged({input}) then
    assert(not self.consuming, "Buffered input taken after ritual delivery began; inspect site before recovery")
    self:beginReturn("Buffered input taken; yielding without starting ritual")
    return
  end
  if not self:lpReady() then return end
  local h = self.config.hardware
  if self.hw:deliverInput(input.descriptor, input.slot, input.role == "focus" and h.focusSlot or h.catalystSlot) then
    self.consuming = true
    self:transition("DELIVERY", "Waiting for " .. input.role .. " to leave drop inventory")
  end
end
function Controller:event(event)
  -- Latch a short pulse; polling alone cannot observe a pulse between ticks.
  if event[1] ~= "redstone_changed" then return end
  local h = self.config.hardware
  if event[2] ~= h.filler or event[3] ~= h.fillerInSide then return end
  if self.state ~= "FILLER" or type(event[5]) ~= "number" then return end
  if event[5] == 0 then
    self.fillerSawWork = true
  elseif self.fillerSawWork or event[4] == 0 then
    self.fillerComplete = true
  end
end
function Controller:tick()
  if self.state == "FAULT" then return end
  local now = self.clock()
  if self.state == "PULSE" then
    if now - self.since >= PULSE_SECONDS then
      self.hw:ritualOutput(false)
      self:transition("METEOR", "Ritual pulsed; waiting for meteor impact")
    end
    return -- Never spend a network scan extending a pulse.
  end
  if now >= self.nextStock then self:refresh() end
  if self.state == "IDLE" then
    if self.mode == "stopped" then return end
    if now < self.nextCycle then self.detail = "Processing cooldown: " .. math.ceil(self.nextCycle - now) .. "s"; return end
    if now < self.nextPrepare then return end
    self.nextPrepare = now + 1
    if self.mode == "auto" then
      local found, started = false, false
      model.eachDeficit(self.rows, self.lastProduct, function(row)
        found, self.lastProduct = true, row.key
        if self:prepare(row.policy.meteor, row.policy.craft) then
          started = true
          return false
        end
      end)
      if not found then self.detail = "All active targets satisfied (or no products activated)"
      elseif not started then self.detail = "Waiting for inputs across active stock deficits" end
    elseif self.mode == "loop" or self.mode == "once" then
      self:prepare(self.manualRecipe, self.config.manualCraft)
    end
  elseif self.state == "STAGING" then self:stageTick()
  elseif self.state == "RETURNING" then self:returnTick()
  elseif self.state == "LP" then
    if not self.hw:verifyStaged(self.inputs) then self:beginReturn("Buffered input taken; yielding without starting ritual")
    elseif self:lpReady() then self:beginInput(self.config.useCatalyst and "catalyst" or "focus") end
  elseif self.state == "INPUT" then self:inputTick()
  elseif self.state == "DELIVERY" then
    assert(now - self.since < self.config.inputTimeout, "Drop inventory failed to drain")
    if self.hw:emptyOutput() then
      if self.input.role == "catalyst" then
        self:transition("MELT", "Catalyst delivered; fixed 30 seconds for melting and reagent transfer")
      else
        self:transition("ARM", "Focus delivered; checking live LP immediately before pulse")
      end
    end
  elseif self.state == "MELT" then
    if now - self.since >= CATALYST_SECONDS then self:beginInput("focus") end
  elseif self.state == "ARM" then
    assert(now - self.since < math.min(240, self.config.inputTimeout), "LP changed after dropping focus; recover before the item despawns")
    if self:lpReady() then
      self.hw:ritualOutput(true)
      self:transition("PULSE", "Activating ritual (external crystal activator)")
    end
  elseif self.state == "METEOR" then
    if now - self.since >= self.config.meteorWait then
      self.hw:startPlants()
      self.nextPlant = 0
      self:transition("MINING", "Ore Drilling Plants running; waiting for every plant to finish")
    end
  elseif self.state == "MINING" then
    assert(now - self.since < self.config.miningTimeout, "Mining timed out; no completion inferred from inactivity")
    if now >= self.nextPlant then
      self.nextPlant = now + 0.1
      if self.hw:pollPlants() then
        self.fillerComplete, self.fillerSawWork = false, false
        self:transition("FILLER", "All Ore Drilling Plants stopped; enabling filler (idle HIGH is normal)")
        self.hw:fillerOutput(true)
      end
    end
  elseif self.state == "FILLER" then
    assert(now - self.since < self.config.fillerTimeout, "Filler completion timed out")
    -- Before enabling, HIGH may mean merely inactive. Give the circuit its
    -- configured reaction time; afterward HIGH means no work, including an
    -- already-clear area. Pulses observed while enabled are latched.
    if now - self.since >= self.config.fillerStartDelay and (self.fillerComplete or self.hw:fillerNoWork()) then
      self.hw:fillerOutput(false)
      self.journal(false)
      self:log("Cycle complete: " .. self.recipe.label)
      self.recipe, self.input = nil, nil
      self.inputs, self.stageRecord = nil, nil
      if self.mode == "once" then self.mode = "stopped" end
      self.nextCycle, self.nextStock = now + self.config.cooldown, 0
      self:transition("IDLE", "Waiting for ore processing and fresh ME stock")
    end
  end
end
function Controller:view()
  return {state = self.state, mode = self.mode, recipe = self.recipe and self.recipe.label,
    detail = self.detail, lp = self.lp, plants = self.hw.plants, rows = self.rows,
    logs = self.logs, lastError = self.lastError}
end
return M
