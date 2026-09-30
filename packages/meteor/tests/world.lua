-- Behavioural fixture: physical time, plant processing/retraction, ME, no-work I/O.
local identity = require("meteor.identity")
local M = {}
function M.item(name, damage, tag)
  return {kind = "item", name = name, damage = damage or 0, hasTag = tag ~= nil, tag = tag, label = name}
end
local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end
function M.new(config, recipe)
  local w = {time = 0, lp = 9000000, items = {}, fluids = {}, transfers = {}, requests = 0,
    pulses = 0, outputs = {ritual = 0, filler = 0}, done = true, plantStates = {}, events = {}, config = config,
    stock = {}, jobs = {}, crafted = true, recipe = recipe, completeMining = true,
    fillerStartupDelay = 0.3, fillerDuration = 2}
  local h = config.hardware
  h.me, h.transposer, h.ritual, h.filler, h.owner = "me", "tp", "ritual", "filler", "Owner"
  function w:add(d, amount)
    local key = identity.key(d)
    w.items[key] = copy(d)
    w.stock[key] = amount
  end
  function w:advance(seconds)
    self.time = self.time + seconds
    for _, job in ipairs(self.jobs) do
      if not job.done and not job.failed and not job.canceled and self.time >= job.at then
        job.done = true
        self:add(job.descriptor, (self.stock[identity.key(job.descriptor)] or 0) + 1)
      end
    end
    for _, plant in ipairs(self.plantStates) do
      if plant.started and plant.allowed then
        local age = self.time - plant.started
        if self.failPlantStart then
          plant.allowed, plant.work, plant.active = false, false, false
        elseif (self.retractBlocked and age >= plant.duration - 2) or (not self.completeMining and age >= plant.duration) then
          plant.work, plant.active, plant.maximum = false, false, 0
        elseif age >= plant.duration then
          plant.allowed, plant.work, plant.active, plant.finished = false, false, false, true
          plant.maximum, plant.progress = 0, 0
        else
          plant.work, plant.active = true, true
          plant.phase = age >= plant.duration - 2 and "UPWARD" or "DOWNWARD"
          plant.maximum = plant.phase == "UPWARD" and 20 or 320
          plant.progress = math.floor(age * 20) % plant.maximum
        end
      end
    end
    local oldNoWork = self.done
    if self.outputs.filler > 0 and self.fillerAt then
      local age = self.time - self.fillerAt
      if age >= self.fillerStartupDelay and not self.noFillerWork then
        if age >= self.fillerStartupDelay + self.fillerDuration and not self.noFillerDone then
          self.done = not self.pulseOnly
          if not self.fillerReported and self.pulseOnly then
            self.events[#self.events + 1] = {"redstone_changed", "filler", h.fillerInSide, 0, 15}
            self.events[#self.events + 1] = {"redstone_changed", "filler", h.fillerInSide, 15, 0}
          end
          self.fillerReported = true
        else
          self.done = false
        end
      end
    end
    if self.done ~= oldNoWork then
      self.events[#self.events + 1] = {"redstone_changed", "filler", h.fillerInSide, oldNoWork and 15 or 0, self.done and 15 or 0}
    end
  end
  local function filtered(d, f)
    for k, v in pairs(f or {}) do if d[k] ~= v then return false end end
    return true
  end
  local me = {}
  function me.getItemsInNetwork(filter)
    if w.networkDown then error("ME disconnected") end
    local result = {}
    for key, d in pairs(w.items) do
      if filtered(d, filter) then local stack = copy(d); stack.size = w.stock[key] or 0; result[#result + 1] = stack end
    end
    return result
  end
  function me.getFluidsInNetwork() if w.networkDown then error("ME disconnected") end; return w.fluids end
  function me.getInterfaceConfiguration(slot) return w.reservation end
  function me.setInterfaceConfiguration(slot, d)
    if w.failClear and not d then error("clear failed") end
    w.reservation = d and copy(d) or nil
    return true
  end
  function me.getCraftables(filter)
    if not w.crafted then return {} end
    local descriptor = copy(filter)
    descriptor.kind, descriptor.label = "item", filter.name
    return {{getStack = function() return descriptor end, request = function(amount)
      assert(amount == 1)
      w.requests = w.requests + 1
      local state = {at = w.time + 2, descriptor = descriptor}
      w.jobs[#w.jobs + 1] = state
      return {hasFailed = function() return state.failed or false, "simulated failure" end,
        isCanceled = function() return state.canceled or false end,
        isDone = function() return state.done or false end}
    end}}
  end
  local tp = {}
  function tp.getInventorySize(side) return 9 end
  function tp.getStackInSlot(side, slot)
    if side == h.orbSide then
      if w.missingOrb then return nil end
      return {name = "AWWayofTime:archmageBloodOrb", damage = 0, hasTag = true, ownerName = w.owner or h.owner,
        orbTier = 5, networkEssence = w.lp, size = 1}
    elseif side == h.sourceSide and w.reservation then
      local d = copy(w.reservation)
      if (w.stock[identity.key(d)] or 0) > 0 then d.size = 1; return d end
    elseif side == h.outputSide then return w.blockOutput end
  end
  function tp.transferItem(source, target, amount, fromSlot, toSlot)
    if w.blockTransfer then return 0 end
    assert(source == h.sourceSide and target == h.outputSide and amount == 1)
    local d = copy(w.reservation)
    local key = identity.key(d)
    assert((w.stock[key] or 0) >= 1)
    w.stock[key] = w.stock[key] - 1
    w.transfers[#w.transfers + 1] = {time = w.time, descriptor = d, slot = toSlot}
    if toSlot == h.focusSlot then w.focusAt = w.time else w.catalystAt = w.time end
    return 1
  end
  local ritual = {setOutput = function(side, strength)
    assert(side == h.ritualSide)
    if strength > 0 and w.outputs.ritual == 0 then
      w.pulses = w.pulses + 1
      w.pulseAt = w.time
      assert(w.focusAt, "Ritual before focus")
      if w.catalystAt then assert(w.time - w.catalystAt >= 30, "Catalyst not ready") end
      assert(w.outputs.filler == 0, "Ritual overlaps filler")
      if not w.failedActivation then w.lp = w.lp - recipe.lp - 100000 end
    elseif strength == 0 and w.outputs.ritual > 0 then
      w.pulseDuration = w.time - w.pulseAt
    end
    w.outputs.ritual = strength
  end}
  local filler = {getInput = function(side) assert(side == h.fillerInSide); return w.done and 15 or 0 end,
    setOutput = function(side, strength)
      assert(side == h.fillerOutSide)
      if strength > 0 and w.outputs.filler == 0 then
        for _, plant in ipairs(w.plantStates) do assert(plant.finished and not plant.allowed and not plant.work, "Filler before plant finished retracting") end
        w.fillerAt, w.fillerReported = w.time, false
      elseif strength == 0 then w.done = true end
      w.outputs.filler = strength
    end}
  w.proxies = {me = me, tp = tp, ritual = ritual, filler = filler}
  w.types = {me = "me_interface", tp = "transposer", ritual = "redstone", filler = "redstone"}
  function w:addPlant(address, duration, tier)
    local plant = {allowed = false, active = false, work = false, duration = duration or 4, maximum = 0, progress = 0}
    self.plantStates[#self.plantStates + 1] = plant
    self.types[address] = "gt_machine"
    self.proxies[address] = {
      getName = function() return "multimachine.oredrill" .. tostring(tier or 1) end,
      setWorkAllowed = function(allowed)
        plant.allowed = allowed
        if allowed then
          assert(w.time - w.pulseAt >= config.meteorWait, "Plant before impact wait")
          plant.work, plant.active, plant.started, plant.finished = false, false, w.time, false
        else
          plant.work, plant.active, plant.maximum = false, false, 0
        end
      end,
      isWorkAllowed = function() return plant.allowed end,
      hasWork = function() return plant.work end,
      isMachineActive = function() return plant.active end,
      getWorkProgress = function() return plant.progress end,
      getWorkMaxProgress = function() return plant.maximum end,
    }
    return plant
  end
  w.component = {
    list = function()
      local keys = {}
      for address in pairs(w.types) do keys[#keys + 1] = address end
      table.sort(keys)
      local i = 0
      return function() i = i + 1; return keys[i], w.types[keys[i]] end
    end,
    proxy = function(address) assert(w.proxies[address], "missing component"); return w.proxies[address] end,
    type = function(address) return w.types[address] end,
  }
  w:add(recipe.focus, 4)
  w:add(recipe.catalyst, 4)
  return w
end
return M
