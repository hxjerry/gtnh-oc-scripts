local model = require("meteor.model")
local M, Controller = {}, {}
Controller.__index = Controller
local CATALYST_SECONDS, PULSE_SECONDS = 30, 0.25
function M.new(config, catalog, hardware, clock, journal)
  return setmetatable({config = config, catalog = catalog, hw = hardware, clock = clock,
    journal = journal, state = "IDLE", mode = "stopped", logs = {}, rows = {}, detail = "Configure hardware, map products, then select a mode",
    nextStock = 0, nextPlant = 0, nextCycle = 0}, Controller)
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
function Controller:boot(interrupted)
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
  self.hw:preparePlants()
  self.hw:readLP()
  self.journal(false)
  self.recipe, self.input, self.lastError, self.mode = nil, nil, nil, "stopped"
  self:transition("IDLE", "Recovery acknowledged; site clear, MRS inactive, Ore Drilling Plants stopped")
end
function Controller:stop()
  self.mode = "stopped"
  if self.state ~= "IDLE" and self.state ~= "FAULT" then
    self:fault("Operator stopped cycle; recover physical site before restarting")
  else
    local ok, err = self.hw:safe()
    if not ok then self:fault(err) end
  end
end
function Controller:auto()
  assert(self.state == "IDLE", "Recover before starting automation")
  model.validate(self.config, self.catalog)
  self.mode, self.nextCycle, self.nextStock = "auto", self.clock(), 0
  self:log("Stock automation enabled")
end
function Controller:run(id, loop)
  assert(self.state == "IDLE", "Another task is running or recovery is required")
  self.manualRecipe, self.mode = id, loop and "loop" or "once"
  self:begin(id, self.config.manualCraft)
end
function Controller:refresh()
  self.rows = model.aggregate(self.config, self.catalog)
  local counts = self.hw:stock(self.rows)
  for _, row in ipairs(self.rows) do row.stock = counts[row.key] end
  self.nextStock = self.clock() + 5
end
function Controller:begin(id, craft)
  local recipe = model.recipe(self.catalog, id)
  assert(self.hw:emptyOutput(), "Drop inventory not empty; refusing another focus")
  self.hw:preparePlants()
  -- Durable intent precedes every externally visible effect, including crafting.
  self.journal(true, id)
  self.recipe, self.craft, self.input = recipe, craft, nil
  self.requiredLP = recipe.lp + self.catalog.activationLP + self.config.reserveLP
  self:transition("LP", "Waiting for " .. self.requiredLP .. " LP: " .. recipe.label)
end
function Controller:lpReady()
  self.lp = self.hw:readLP()
  if self.lp < self.requiredLP then
    self.detail = "LP " .. self.lp .. " / " .. self.requiredLP .. "; ritual inhibited"
    return false
  end
  return true
end
function Controller:beginInput(descriptor, role)
  self.input = {descriptor = descriptor, role = role, started = self.clock()}
  self:transition("INPUT", "Fetching " .. role .. ": " .. descriptor.name)
end
function Controller:inputTick()
  local input, now = self.input, self.clock()
  assert(now - input.started < self.config.inputTimeout, "Input timed out: " .. input.descriptor.name)
  if input.job then
    local failed, why = input.job.hasFailed()
    assert(not failed, "Autocraft failed: " .. tostring(why))
    local canceled, reason = input.job.isCanceled()
    assert(not canceled, "Autocraft canceled: " .. tostring(reason))
    local done = input.job.isDone()
    assert(done or now - input.craftAt < self.config.craftTimeout, "Autocraft timed out")
  end
  if not input.reserved then
    local count = self.hw:inputCount(input.descriptor)
    if count < 1 then
      if self.craft and not input.job then
        input.job, input.craftAt = self.hw:request(input.descriptor), now
        self:log("Requested one exact " .. input.role .. " via ME autocrafting")
      end
      self.detail = input.job and "Waiting for requested autocraft" or "Input absent; autocrafting disabled for this task"
      return
    end
    self.hw:reserveInput(input.descriptor)
    input.reserved = true
  end
  if not self:lpReady() then return end
  local h = self.config.hardware
  if self.hw:transferInput(input.descriptor, input.role == "focus" and h.focusSlot or h.catalystSlot) then
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
    if now < self.nextCycle then self.detail = "Processing cooldown: " .. math.ceil(self.nextCycle - now) .. "s"; return end
    if self.mode == "auto" then
      local task = model.choose(self.rows, self.lastProduct)
      if task then self.lastProduct = task.key; self:begin(task.recipe, task.craft)
      else self.detail = "All active targets satisfied (or no products activated)" end
    elseif self.mode == "loop" then self:begin(self.manualRecipe, self.config.manualCraft) end
  elseif self.state == "LP" then
    if self:lpReady() then
      if self.config.useCatalyst then self:beginInput(self.recipe.catalyst, "catalyst")
      else self:beginInput(self.recipe.focus, "focus") end
    end
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
    if now - self.since >= CATALYST_SECONDS then self:beginInput(self.recipe.focus, "focus") end
  elseif self.state == "ARM" then
    assert(now - self.since < math.min(240, self.config.inputTimeout), "LP changed after dropping focus; recover before the item despawns")
    if self:lpReady() then
      self.beforePulseLP, self.debitSeen = self.lp, false
      self.hw:ritualOutput(true)
      self:transition("PULSE", "Activating ritual (external crystal activator)")
    end
  elseif self.state == "METEOR" then
    self.lp = self.hw:readLP()
    if self.beforePulseLP - self.lp >= self.recipe.lp + self.catalog.activationLP then self.debitSeen = true end
    if now - self.since >= self.config.meteorWait then
      assert(self.debitSeen, "No full ritual LP debit observed; check activator/focus (fast LP refill can mask debit)")
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
