package.path = "packages/meteor/lib/?.lua;packages/meteor/tests/?.lua;" .. package.path
local identity, model = require("meteor.identity"), require("meteor.model")
local hardware, controller, world = require("meteor.hardware"), require("meteor.controller"), require("world")
local total = 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then io.stderr:write("FAIL " .. name .. "\n" .. err .. "\n"); os.exit(1) end
  total = total + 1
  print("PASS " .. name)
end
local function raises(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok and (not pattern or tostring(err):find(pattern, 1, true)), tostring(err))
end
local recipe = {id = "iron", label = "Iron Meteor", focus = world.item("gregtech:gt.blockmachines", 463),
  catalyst = world.item("AWWayofTime:bloodMagicBaseAlchemyItems", 2), lp = 2000000, ores = {{key = "OREDICT:oreIron", weight = 100}}}
local product = world.item("gregtech:gt.metaitem.01", 2032)
local function setup(options)
  options = options or {}
  local config = {hardware = {sourceSide = 2, orbSide = 0, orbSlot = 1, outputSide = 3, focusSlot = 1, catalystSlot = 2,
    interfaceSlot = 1, ritualSide = 1, fillerOutSide = 1, fillerInSide = 2}, reserveLP = 100000,
    useCatalyst = options.catalyst ~= false, manualCraft = options.craft == true, inputTimeout = 10,
    craftTimeout = 8, meteorWait = 2, miningTimeout = 20, fillerTimeout = 5, fillerStartDelay = 1, cooldown = 3,
    oreProducts = {["OREDICT:oreIron"] = {product}}, policies = {}}
  local catalog = {activationLP = 100000, recipes = {recipe}}
  local w = world.new(config, recipe)
  w:addPlant("plant-1", 3, 1)
  w:addPlant("plant-2", 7, 4)
  w:add(product, 0)
  local hw = hardware.new(w.component, config):connect()
  local journal = {}
  local c = controller.new(config, catalog, hw, function() return w.time end,
    function(dirty, id, staging) journal.dirty, journal.recipe, journal.staging = dirty, id, staging end)
  c:boot(false)
  return c, w, config, journal, hw
end
local function tick(c, w, duration)
  local steps = math.floor((duration or 0.1) / 0.1 + 0.5)
  for _ = 1, steps do
    w:advance(0.1)
    for _, e in ipairs(w.events) do c:event(e) end
    w.events = {}
    local ok, err = pcall(c.tick, c)
    if not ok then c:fault(err) end
  end
end
local function untilState(c, w, state, seconds)
  for _ = 1, math.ceil((seconds or 90) * 10) do
    tick(c, w)
    if c.state == state and (state ~= "IDLE" or w.pulses > 0) then return end
    assert(c.state ~= "FAULT", c.lastError)
  end
  error("Never reached " .. state .. "; " .. c.state .. " " .. c.detail)
end

test("exact metadata and binary NBT identity", function()
  local a, b = world.item("mod:meta", 1, "\0\255one"), world.item("mod:meta", 1, "\0\255two")
  assert(not identity.same(a, b))
  b = world.item("mod:meta", 2, a.tag)
  assert(not identity.same(a, b))
  b = world.item("mod:meta", 1, a.tag); b.label = "renamed"; b.size = 600
  assert(identity.same(a, b))
  raises(function() identity.fromStack({name = "mod:meta", damage = 1, hasTag = true}) end, "NBT unavailable")
  raises(function() identity.fromStack({name = "mod:meta", damage = 1}) end, "NBT visibility unknown")
end)

test("stock aggregation and round-robin policies", function()
  local a = {id = "a", ores = {{key = "oreA"}, {key = "oreB"}}}
  local b = {id = "b", ores = {{key = "oreB"}}}
  local fluid = {kind = "fluid", name = "molten.iron", label = "Molten Iron", hasTag = false}
  local cfg = {oreProducts = {oreA = {product}, oreB = {product, fluid}}, policies = {}}
  cfg.policies[identity.key(product)] = {active = true, meteor = "b", target = 32, craft = true}
  cfg.policies[identity.key(fluid)] = {active = true, meteor = "a", target = 1000, craft = false}
  local rows = model.aggregate(cfg, {recipes = {a, b}})
  assert(#rows == 2)
  for _, row in ipairs(rows) do assert(#row.meteors == 2); row.stock = 0 end
  local first = model.choose(rows)
  local second = model.choose(rows, first.key)
  assert(first.key ~= second.key)
  for _, row in ipairs(rows) do row.stock = nil end
  assert(model.choose(rows) == nil)
end)

test("serial cycle, 30s catalyst delay, two drilling plants, pulse completion", function()
  local c, w, _, journal = setup()
  w.pulseOnly = true
  c:run("iron", false)
  untilState(c, w, "IDLE")
  assert(#w.transfers == 2 and w.pulses == 1 and w.pulseDuration >= 0.25 and w.pulseDuration < 0.5)
  assert(w.transfers[2].time - w.transfers[1].time >= 30)
  assert(journal.dirty == false and c.mode == "stopped")
  assert(w.outputs.ritual == 0 and w.outputs.filler == 0)
end)

test("held no-work HIGH remains valid after disabling filler", function()
  local c, w = setup({catalyst = false})
  c:run("iron", false)
  untilState(c, w, "IDLE")
  assert(#w.transfers == 1 and w.pulses == 1)
  assert(w.fillerReported and w.done and w.outputs.filler == 0)
end)

test("low LP permits buffering but blocks delivery and activation", function()
  local c, w = setup()
  w.lp = 2199999
  c:run("iron", false)
  tick(c, w, 3)
  assert(c.state == "LP" and #w.transfers == 0 and w.pulses == 0)
  assert(#w.staged == 2 and w.buffer[2] and w.buffer[3])
  w.lp = 2200000
  tick(c, w, 1)
  assert(#w.transfers == 1)
end)

test("wrong orb owner refuses preparation before moving inputs", function()
  local c, w = setup()
  w.owner = "SomeoneElse"
  raises(function() c:run("iron", false) end, "owner")
  assert(w.pulses == 0 and #w.staged == 0 and #w.transfers == 0)
end)

test("missing stock skips without autocrafting permission or dirtying the site", function()
  local c, w, _, journal = setup({catalyst = false})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  tick(c, w, 12)
  assert(c.state == "IDLE" and c.recipe == nil and w.requests == 0 and w.pulses == 0 and not journal.dirty)
  c:stop()
  w:add(recipe.focus, 1)
  tick(c, w, 3)
  assert(c.mode == "stopped" and #w.staged == 0)
end)

test("autocraft waits for one exact requested input", function()
  local c, w = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  untilState(c, w, "IDLE")
  assert(w.requests == 1 and w.pulses == 1)
end)

test("canceled crafting yields and retries only after the configured interval", function()
  local c, w, cfg = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  w.jobs[1].canceled = true
  tick(c, w, cfg.craftTimeout - 1)
  assert(c.state == "IDLE" and w.requests == 1 and w.pulses == 0)
  untilState(c, w, "IDLE")
  assert(w.requests == 2 and w.pulses == 1)
end)

test("saved computing and live craft statuses suppress duplicates beyond timeout", function()
  local c, w, cfg, _, hw = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  w.computeDelay, w.jobDelay = 12, 24
  c:run("iron", false)
  local job = assert(w.jobs[1])
  w:saveCraftStatuses()
  tick(c, w, cfg.craftTimeout + 2)
  assert(job.computing and w.requests == 1 and c.state == "IDLE" and #w.staged == 0)
  tick(c, w, 3)
  assert(job.linked and not job.done)
  w:saveCraftStatuses()
  tick(c, w, cfg.craftTimeout + 1)
  assert(w.requests == 1 and c.state == "IDLE" and #w.transfers == 0)
  untilState(c, w, "IDLE")
  assert(w.requests == 1 and w.pulses == 1 and identity.same(w.transfers[1].descriptor, recipe.focus))
  assert(not hw.ownsSlot)
end)

test("rejected craft does not block exact inputs supplied by another source", function()
  local c, w = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  local job = assert(w.jobs[1])
  job.failed, job.computing = true, false
  w:add(recipe.focus, 1)
  untilState(c, w, "IDLE")
  assert(w.requests == 1 and #w.staged == 1 and w.pulses == 1)
end)

test("unknown request status uses timeout fallback without faulting the scheduler", function()
  local c, w, cfg = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  w.jobDelay = math.huge
  c:run("iron", false)
  w.jobs[1].status.isCanceled = function() error("lost status") end
  w.proxies.me.getCpus = nil
  tick(c, w, cfg.craftTimeout - 1)
  assert(c.state == "IDLE" and w.requests == 1)
  tick(c, w, 2)
  assert(w.requests == 2 and w.pulses == 0 and #w.staged == 0)
end)

test("both missing inputs are requested before yielding; samples and orb remain untouched", function()
  local c, w, cfg, journal = setup({craft = true})
  local sample = world.item("mod:sample", 9, "\0sample")
  w.sampleSlots[cfg.hardware.orbSide] = {[2] = {stack = sample}}
  w.stock[identity.key(recipe.focus)], w.stock[identity.key(recipe.catalyst)] = 0, 0
  c:run("iron", false)
  assert(w.requests == 2 and c.recipe == nil and c.state == "IDLE" and not journal.dirty)
  assert(identity.same(w.jobs[1].descriptor, recipe.catalyst) and identity.same(w.jobs[2].descriptor, recipe.focus))
  untilState(c, w, "LP")
  assert(#w.staged == 2 and w.staged[1].slot == 3 and w.staged[2].slot == 4 and journal.dirty)
  assert(identity.same(w.sampleSlots[0][2].stack, sample) and w.proxies.tp.getStackInSlot(0, 1).ownerName == "Owner")
  assert(#w.transfers == 0)
  untilState(c, w, "IDLE")
  assert(w.pulses == 1 and w.requests == 2 and next(w.buffer) == nil)
end)

test("unavailable meteor yields to a runnable deficit with or without craft permission", function()
  for _, craft in ipairs({false, true}) do
    local c, w, cfg = setup({catalyst = false})
    local focus = world.item("gregtech:gt.blockmachines", 464)
    local other = world.item("mod:product", 1); other.label = "Z runnable"
    c.catalog.recipes[2] = {id = "ready", label = "Ready Meteor", focus = focus, catalyst = recipe.catalyst,
      lp = recipe.lp, ores = {{key = "oreReady", weight = 100}}}
    cfg.oreProducts.oreReady = {other}
    cfg.policies[identity.key(product)] = {active = true, target = 10, meteor = "iron", craft = craft}
    cfg.policies[identity.key(other)] = {active = true, target = 10, meteor = "ready", craft = false}
    w:add(focus, 1)
    w.stock[identity.key(recipe.focus)] = 0
    w.jobDelay = math.huge
    c.lastProduct = identity.key(other)
    c:auto()
    tick(c, w, 0.1)
    assert(c.state == "IDLE" and c.recipe == nil and w.requests == (craft and 1 or 0))
    untilState(c, w, "LP", 3)
    assert(c.recipe.id == "ready" and identity.same(w.staged[1].descriptor, focus))
    untilState(c, w, "IDLE")
    assert(w.pulses == 1 and identity.same(w.transfers[1].descriptor, focus))
  end
end)

test("shared catalyst across deficits keeps one live request per exact item", function()
  local c, w, cfg = setup()
  local focus = world.item(recipe.focus.name, recipe.focus.damage + 1)
  local other = world.item("mod:product", 2)
  c.catalog.recipes[2] = {id = "other", label = "Other", focus = focus, catalyst = recipe.catalyst,
    lp = recipe.lp, ores = {{key = "oreOther", weight = 100}}}
  cfg.oreProducts.oreOther = {other}
  cfg.policies[identity.key(product)] = {active = true, target = 1, meteor = "iron", craft = true}
  cfg.policies[identity.key(other)] = {active = true, target = 1, meteor = "other", craft = true}
  w:add(focus, 0)
  w.stock[identity.key(recipe.focus)], w.stock[identity.key(recipe.catalyst)] = 0, 0
  w.jobDelay = math.huge
  c:auto()
  tick(c, w, 20)
  local catalysts = 0
  for _, job in ipairs(w.jobs) do if identity.same(job.descriptor, recipe.catalyst) then catalysts = catalysts + 1 end end
  assert(w.requests == 3 and catalysts == 1 and c.state == "IDLE" and #w.staged == 0)
end)

test("external exact crafting output suppresses requests; other metadata and NBT do not", function()
  local c, w = setup({catalyst = false, craft = true})
  local focus = world.item("mod:focus", 5, "\0wanted")
  c.catalog.recipes = {{id = "tagged", label = "Tagged", focus = focus, catalyst = recipe.catalyst,
    lp = recipe.lp, ores = recipe.ores}}
  w:add(focus, 0)
  local external = {descriptor = focus}
  w.externalJobs = {external}
  c:run("tagged", false)
  tick(c, w, 20)
  assert(w.requests == 0 and c.state == "IDLE")
  external.descriptor = world.item(focus.name, focus.damage, "\0other")
  w.externalJobs[2] = {descriptor = world.item(focus.name, focus.damage + 1, focus.tag)}
  tick(c, w, 2)
  assert(w.requests == 1 and identity.same(w.jobs[1].descriptor, focus))
  untilState(c, w, "IDLE")
  assert(w.pulses == 1 and identity.same(w.transfers[1].descriptor, focus))
end)

test("unobservable busy CPU gets startup timeout fallback", function()
  local c, w, cfg = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  w.externalJobs = {{descriptor = recipe.focus}}
  w.noCraftMonitor, w.jobDelay = true, math.huge
  c:run("iron", false)
  tick(c, w, cfg.craftTimeout - 1)
  assert(w.requests == 0 and c.state == "IDLE")
  tick(c, w, 2)
  assert(w.requests == 1)
  tick(c, w, cfg.craftTimeout + 1)
  assert(w.requests == 1 and c.state == "IDLE") -- Own live link remains observable without a monitor.
end)

test("identical focus and catalyst need two copies but only one craft request", function()
  local c, w = setup({craft = true})
  c.catalog.recipes = {{id = "same", label = "Same", focus = recipe.focus, catalyst = recipe.focus,
    lp = recipe.lp, ores = recipe.ores}}
  w.stock[identity.key(recipe.focus)] = 0
  c:run("same", false)
  assert(w.requests == 1 and w.jobs[1].amount == 2)
  untilState(c, w, "IDLE")
  assert(#w.staged == 2 and #w.transfers == 2 and w.pulses == 1 and w.stock[identity.key(recipe.focus)] == 0)
end)

test("full orb inventory yields without overwriting existing items", function()
  local c, w, _, journal = setup()
  w.sampleSlots[0] = {}
  for slot = 2, 9 do w.sampleSlots[0][slot] = {stack = world.item("mod:sample", slot)} end
  c:run("iron", false)
  tick(c, w, 3)
  assert(c.state == "IDLE" and not journal.dirty and #w.staged == 0)
  w.sampleSlots[0][8], w.sampleSlots[0][9] = nil, nil
  untilState(c, w, "LP")
  assert(w.staged[1].slot == 8 and w.staged[2].slot == 9 and w.sampleSlots[0][2].stack.damage == 2)
end)

test("buffered ritual delivery has no ME fetch or crafting dependency", function()
  local c, w = setup()
  c:run("iron", false)
  untilState(c, w, "LP")
  w.networkDown, c.nextStock = true, math.huge
  untilState(c, w, "IDLE")
  assert(w.pulses == 1 and w.requests == 0 and #w.staged == 2 and #w.transfers == 2 and next(w.buffer) == nil)
end)

test("changed buffered metadata faults before delivery", function()
  local c, w, _, journal = setup({catalyst = false})
  c:run("iron", false)
  untilState(c, w, "LP")
  w.buffer[2].damage = w.buffer[2].damage + 1
  tick(c, w, 1)
  assert(c.state == "FAULT" and #w.transfers == 0 and w.pulses == 0 and journal.dirty)
end)

test("stop and hardware rebinding preserve a live request without duplicate orders", function()
  local c, w, cfg = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  w.jobDelay = math.huge
  c:run("iron", false)
  c:stop()
  c.hw = hardware.new(w.component, cfg):connect()
  w.proxies.me.getCpus = nil
  c:run("iron", false)
  tick(c, w, cfg.craftTimeout + 2)
  assert(w.requests == 1 and c.state == "IDLE")
  w.jobs[1].at = w.time + 1
  untilState(c, w, "IDLE")
  assert(w.pulses == 1 and w.requests == 1)
end)

test("craft submission errors defer retries without faulting or blocking another input request", function()
  local c, w, cfg, journal = setup({craft = true})
  w.stock[identity.key(recipe.focus)], w.stock[identity.key(recipe.catalyst)] = 0, 0
  local craftable = w.proxies.me.getCraftable
  w.proxies.me.getCraftable = function(filter, kind)
    if filter.name == recipe.catalyst.name then error("request rejected") end
    return craftable(filter, kind)
  end
  c:run("iron", false)
  tick(c, w, cfg.craftTimeout + 1)
  assert(c.state == "IDLE" and c.recipe == nil and w.requests == 1 and not journal.dirty and #w.staged == 0)
end)

test("missing patterns and rejected submissions stay nonfaulting until crafting becomes available", function()
  local c, w, cfg = setup({catalyst = false})
  cfg.policies[identity.key(product)] = {active = true, target = 1, meteor = "iron", craft = true}
  w.stock[identity.key(recipe.focus)] = 0
  w.crafted = false
  c:auto()
  tick(c, w, 12)
  assert(c.state == "IDLE" and w.requests == 0 and w.pulses == 0)
  w.crafted = true
  local lookup = w.proxies.me.getCraftable
  w.proxies.me.getCraftable = function(filter, kind)
    local craftable = lookup(filter, kind)
    craftable.request = function() return nil, "no controller" end
    return craftable
  end
  tick(c, w, 10)
  assert(c.state == "IDLE" and w.requests == 0 and w.pulses == 0)
  w.proxies.me.getCraftable = lookup
  untilState(c, w, "IDLE")
  assert(w.requests == 1 and w.pulses == 1)
end)

test("submission error after enqueue uses CPU output to prevent duplicate orders", function()
  local c, w, cfg = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  w.jobDelay = math.huge
  local lookup = w.proxies.me.getCraftable
  w.proxies.me.getCraftable = function(filter, kind)
    local craftable = lookup(filter, kind)
    local request = craftable.request
    craftable.request = function(amount)
      request(amount)
      error("response lost after enqueue")
    end
    return craftable
  end
  c:run("iron", false)
  tick(c, w, cfg.craftTimeout * 3)
  assert(c.state == "IDLE" and w.requests == 1 and #w.staged == 0 and w.pulses == 0)
end)

test("completed craft taken by player is requested again without a fault", function()
  local c, w, cfg = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  w:advance(2.1)
  assert(w.jobs[1].done)
  w.stock[identity.key(recipe.focus)] = 0 -- Taken before the next controller observation.
  tick(c, w, cfg.craftTimeout - w.time - 1)
  assert(c.state == "IDLE" and w.requests == 1)
  untilState(c, w, "IDLE")
  assert(w.requests == 2 and w.pulses == 1)
end)

test("failed input observation yields without fabricating zero stock or ordering", function()
  local c, w, cfg, journal = setup({catalyst = false, craft = true})
  local lookup = w.proxies.me.getItemInNetwork
  w.proxies.me.getItemInNetwork = function(filter)
    if filter.name == recipe.focus.name then return nil, "temporary query failure" end
    return lookup(filter)
  end
  cfg.policies[identity.key(product)] = {active = true, target = 1, meteor = "iron", craft = true}
  c:auto()
  tick(c, w, 10)
  assert(c.state == "IDLE" and w.requests == 0 and #w.staged == 0 and not journal.dirty)
end)

test("stock taken during staging returns the partial buffer then yields without fault", function()
  local c, w, _, journal = setup()
  c:run("iron", false)
  tick(c, w, 0.1)
  assert(#w.staged == 1 and identity.same(w.staged[1].descriptor, recipe.catalyst))
  w.stock[identity.key(recipe.focus)] = 0
  tick(c, w, 1)
  assert(c.state == "IDLE" and not journal.dirty and next(w.buffer) == nil and #w.returned == 1)
  assert(w.pulses == 0 and #w.transfers == 0 and w.stock[identity.key(recipe.catalyst)] == 4)
end)

test("buffered item taken before delivery releases remaining inputs without fault", function()
  local c, w, _, journal = setup()
  c:run("iron", false)
  untilState(c, w, "LP")
  w.buffer[3] = nil
  w.stock[identity.key(recipe.focus)] = 0
  tick(c, w, 1)
  assert(c.state == "IDLE" and not journal.dirty and next(w.buffer) == nil and #w.returned == 1)
  assert(w.pulses == 0 and #w.transfers == 0)
end)

test("staging transfer timeout unwinds instead of faulting input preparation", function()
  local c, w, cfg, journal = setup()
  w.blockStage = true
  c:run("iron", false)
  tick(c, w, cfg.inputTimeout + 0.5)
  assert(c.state == "IDLE" and not journal.dirty and not w.reservation and #w.staged == 0 and w.pulses == 0)
end)

test("rejected ME reservation releases preparation without faulting", function()
  local c, w, _, journal = setup({catalyst = false})
  local configure = w.proxies.me.setInterfaceConfiguration
  w.proxies.me.setInterfaceConfiguration = function(slot, descriptor)
    if descriptor then return false end
    return configure(slot)
  end
  c:run("iron", false)
  tick(c, w, 0.5)
  assert(c.state == "IDLE" and not journal.dirty and not w.reservation and #w.staged == 0 and w.pulses == 0)
end)

test("enabled but idle drilling plants never authorize filler", function()
  local c, w = setup({catalyst = false})
  w.completeMining = false
  c:run("iron", false)
  untilState(c, w, "MINING")
  tick(c, w, 21)
  assert(c.state == "FAULT" and w.fillerAt == nil)
end)

test("plant retraction stalls prevent cleanup", function()
  local c, w = setup({catalyst = false})
  w.retractBlocked = true
  c:run("iron", false)
  untilState(c, w, "MINING")
  tick(c, w, 21)
  assert(c.state == "FAULT" and w.fillerAt == nil)
end)

test("idle filler HIGH permits a cycle but does not skip cleanup startup", function()
  local c, w = setup({catalyst = false})
  assert(w.done)
  c:run("iron", true)
  untilState(c, w, "FILLER")
  tick(c, w, 0.8)
  assert(c.state == "FILLER" and w.outputs.filler == 15 and not w.done)
  untilState(c, w, "IDLE")
  assert(w.done and w.pulses == 1)
  untilState(c, w, "MINING")
  assert(w.pulses == 2 and c.mode == "loop")
end)

test("LP refilling after activation does not gate mining or skip the impact wait", function()
  local c, w, cfg = setup({catalyst = false})
  local initialLP = w.lp
  c:run("iron", false)
  untilState(c, w, "PULSE")
  w.lp = initialLP -- An altar can immediately replenish the ritual's cost.
  untilState(c, w, "METEOR")
  tick(c, w, cfg.meteorWait - 0.1)
  assert(c.state == "METEOR" and not w.plantStates[1].started)
  untilState(c, w, "MINING", 1)
  assert(w.pulses == 1 and w.plantStates[1].allowed and w.lp == initialLP)
  untilState(c, w, "IDLE")
  assert(w.fillerReported and w.outputs.filler == 0)
end)

test("plant disconnection stops the whole site", function()
  local c, w = setup({catalyst = false})
  c:run("iron", false)
  untilState(c, w, "MINING")
  w.types["plant-2"] = nil
  tick(c, w, 1.2)
  assert(c.state == "FAULT" and w.outputs.ritual == 0 and w.outputs.filler == 0)
  assert(not w.plantStates[1].allowed)
end)

test("staging followed by clear failure remains journaled and never duplicates input", function()
  local c, w, _, journal = setup({catalyst = false})
  w.failClear = true
  c:run("iron", false)
  tick(c, w, 5)
  assert(c.state == "FAULT" and #w.staged == 1 and #w.transfers == 0 and w.pulses == 0 and journal.dirty)
  w.failClear = false
  raises(function() c:reset() end, "buffer slot")
  assert(journal.dirty)
  w.buffer = {}
  c:reset()
  assert(not journal.dirty and c.mode == "stopped")
end)

test("non-callable ME fields cannot masquerade as required callbacks", function()
  local _, w, cfg = setup()
  w.proxies.me.getItemInNetwork = {}
  local fresh = hardware.new(w.component, cfg)
  raises(function() fresh:connect() end)
  assert(w.pulses == 0 and #w.transfers == 0 and w.outputs.ritual == 0 and w.outputs.filler == 0)
end)

test("only Ore Drilling Plants I-IV are discovered; basic miners are never controlled", function()
  local _, w, cfg, _, hw = setup()
  w:addPlant("plant-3", 6, 2)
  w:addPlant("plant-4", 6, 3)
  w.types["excluded"] = "gt_machine"
  w.proxies["excluded"] = {
    getName = function() return "basicmachine.miner.tier.03" end,
    setWorkAllowed = function() error("Excluded machine was controlled") end,
  }
  local fresh = hardware.new(w.component, cfg):connect()
  assert(#fresh.plants == 4 and #fresh:discover().plants == 4)
  assert(fresh:safe())
  assert(#hw.plants == 2)
end)

test("a plant that stops before working faults instead of finishing", function()
  local c, w = setup({catalyst = false})
  w.failPlantStart = true
  c:run("iron", false)
  untilState(c, w, "MINING")
  tick(c, w, 1)
  assert(c.state == "FAULT" and w.fillerAt == nil)
end)

test("filler pulse from before enabling cannot finish an active cleanup", function()
  local c, w = setup({catalyst = false})
  w.noFillerDone = true
  c:run("iron", false)
  untilState(c, w, "MINING")
  c:event({"redstone_changed", "filler", 2, 0, 15})
  untilState(c, w, "FILLER")
  tick(c, w, 6)
  assert(c.state == "FAULT" and w.outputs.filler == 0 and w.pulses == 1)
end)

test("already-clear filler accepts constant no-work HIGH without a LOW edge", function()
  local c, w, _, journal = setup({catalyst = false})
  w.noFillerWork = true
  c:run("iron", false)
  untilState(c, w, "IDLE")
  assert(w.done and w.outputs.filler == 0 and not journal.dirty)
  assert(w.time - w.fillerAt >= 1)
end)

test("absent item and fluid targets count as zero despite other metadata stock", function()
  local c, w, cfg = setup({catalyst = false})
  local key = identity.key(product)
  w.items[key], w.stock[key] = nil, nil
  w:add(world.item(product.name, product.damage + 1), 1000)
  local fluid = {kind = "fluid", name = "missing.fluid", label = "Missing Fluid", hasTag = false}
  cfg.oreProducts["OREDICT:oreIron"][2] = fluid
  cfg.policies[key] = {active = true, target = 10, meteor = "iron", craft = false}
  cfg.policies[identity.key(fluid)] = {active = true, target = 144, meteor = "iron", craft = false}
  c:auto()
  tick(c, w)
  assert(c.state == "STAGING" and c.recipe == nil)
  for _, row in ipairs(c.rows) do assert(row.stock == 0) end
end)

test("stock refresh failure is not zero stock", function()
  local c, w, cfg = setup({catalyst = false})
  cfg.policies[identity.key(product)] = {active = true, target = 10, meteor = "iron", craft = false}
  w.networkDown = true
  c:auto()
  tick(c, w)
  assert(c.state == "FAULT" and #w.transfers == 0)
end)

test("satisfied targets suppress additional meteor cycles", function()
  local c, w, cfg = setup({catalyst = false})
  cfg.policies[identity.key(product)] = {active = true, target = 10, meteor = "iron", craft = false}
  c:auto()
  untilState(c, w, "FILLER")
  w:add(product, 10)
  untilState(c, w, "IDLE")
  tick(c, w, 10)
  assert(c.state == "IDLE" and w.pulses == 1)
end)

test("interrupted-cycle recovery never replays ritual", function()
  local c, w = setup({catalyst = false})
  c:boot(true)
  tick(c, w, 10)
  assert(c.state == "FAULT" and w.pulses == 0 and c.mode == "stopped")
  raises(function() c:auto() end, "Recover")
end)

test("catalogue nested data cannot be modified", function()
  local cat = require("meteor.catalog")
  local recipe = cat.recipes[1]
  local original = recipe.focus.damage
  raises(function() recipe.focus.damage = 999 end, "immutable")
  assert(recipe.focus.damage == original)
  raises(function() cat.recipes[1] = {} end, "immutable")
end)

test("physical item samples retain metadata and NBT without ME access", function()
  local _, w, cfg = setup()
  local a = world.item("mod:metal", 7, "\0\255a")
  local b = world.item("mod:metal", 7, "\0\255b")
  local otherMeta = world.item("mod:metal", 8, a.tag)
  w.sampleSlots[0] = {[2] = {stack = a}, [3] = {stack = b}, [4] = {stack = otherMeta}}
  w.networkDown = true
  cfg.hardware.me, cfg.hardware.ritual, cfg.hardware.filler = "", "", ""
  local hw = hardware.new(w.component, cfg)
  local first, second, third = hw:sampleProduct(0, 2), hw:sampleProduct(0, 3), hw:sampleProduct(0, 4)
  assert(identity.same(first, a) and identity.same(second, b) and identity.same(third, otherMeta))
  assert(not identity.same(first, second) and not identity.same(first, third))
  assert(identity.same(w.sampleSlots[0][2].stack, a))
end)

test("filled containers register fluid identity rather than the container item", function()
  local _, w, cfg = setup()
  local cell = world.item("mod:cell", 1, "\0container")
  local bucket = world.item("other:bucket", 12)
  w.sampleSlots[0] = {
    [2] = {stack = cell, fluid = {name = "molten.iron", label = "Molten Iron", amount = 144, hasTag = true}},
    [3] = {stack = bucket, fluid = {name = "molten.iron", label = "Iron", amount = 1000, id = 99}},
    [4] = {stack = cell, fluid = {name = "molten.copper", amount = 144}},
  }
  local hw = hardware.new(w.component, cfg)
  local first, second, third = hw:sampleProduct(0, 2), hw:sampleProduct(0, 3), hw:sampleProduct(0, 4)
  assert(first.kind == "fluid" and identity.same(first, second))
  assert(not identity.same(first, third) and not identity.same(first, cell))
  local normalized = identity.fromStack({kind = "fluid", name = first.name, hasTag = true,
    tag = "\0ignored", damage = 123, id = 1, amount = 999})
  assert(identity.same(first, normalized))
  w.fluids = {{name = first.name, amount = 288, hasTag = false}}
  hw:connect()
  assert(hw:stock({{key = identity.key(first), product = first}})[identity.key(first)] == 288)
end)

test("sampling rejects empty slots, invalid bounds and unreadable items without fabricating products", function()
  local _, w, cfg = setup()
  local hw = hardware.new(w.component, cfg)
  raises(function() hw:sampleProduct(4, 1) end)
  for _, location in ipairs({{-1, 1}, {6, 1}, {0.5, 1}, {0, 0}, {0, 10}, {0, 1.5}}) do
    raises(function() hw:sampleProduct(location[1], location[2]) end)
  end
  local hidden = world.item("mod:hidden", 4, "\0secret")
  hidden.tag = nil
  w.sampleSlots[0] = {[2] = {stack = hidden}}
  raises(function() hw:sampleProduct(0, 2) end, "NBT unavailable")
  local emptyCell = world.item("mod:empty_cell", 0)
  w.sampleSlots[0][2] = {stack = emptyCell}
  w.proxies.tp.getFluidInContainerInSlot = function() return nil end
  assert(identity.same(hw:sampleProduct(0, 2), emptyCell))
  w.proxies.tp.getFluidInContainerInSlot = function() return nil, "container inspection failed" end
  raises(function() hw:sampleProduct(0, 2) end, "container inspection failed")
  w.proxies.tp.getStackInSlot = function() return nil, "inventory inspection failed" end
  raises(function() hw:sampleProduct(0, 2) end, "inventory inspection failed")
  assert(identity.same(w.sampleSlots[0][2].stack, emptyCell))
end)

test("monitoring an added product never loads unrelated ME inventory", function()
  local _, w, _, _, hw = setup()
  local a, b = world.item("mod:product", 1, "\0a"), world.item("mod:product", 1, "\0b")
  w:add(a, 12); w:add(b, 900)
  local fluid = {kind = "fluid", name = "molten.iron", label = "Molten Iron", hasTag = false}
  w.fluids = {{name = fluid.name, label = fluid.label, hasTag = false, amount = 288}}
  w.proxies.me.getItemsInNetwork = function() error("Bulk items exceed OC RAM") end
  w.proxies.me.getFluidsInNetwork = function() error("Bulk fluids exceed OC RAM") end
  local rows = {{key = identity.key(a), product = a}, {key = identity.key(fluid), product = fluid}}
  local counts = hw:stock(rows)
  assert(counts[identity.key(a)] == 12 and counts[identity.key(fluid)] == 288)
  w.items[identity.key(a)] = nil
  counts = hw:stock(rows)
  assert(counts[identity.key(a)] == 0 and counts[identity.key(fluid)] == 288)
  w.networkDown = true
  raises(function() hw:stock(rows) end, "ME disconnected")
end)

test("ME quantities remain separate across metadata, NBT and fluid identities", function()
  local _, w, _, _, hw = setup()
  local a, b = world.item("mod:product", 1, "\0a"), world.item("mod:product", 1, "\0b")
  local otherMeta = world.item("mod:product", 2, "\0a")
  w:add(a, 19); w:add(b, 300); w:add(otherMeta, 400)
  local fluid = {kind = "fluid", name = "mod:product", label = "Fluid", hasTag = false}
  w.fluids = {{name = fluid.name, label = fluid.label, hasTag = false, amount = 144000}}
  local rows = {
    {key = identity.key(a), product = a},
    {key = identity.key(b), product = b},
    {key = identity.key(fluid), product = fluid},
  }
  local counts = hw:stock(rows)
  assert(counts[identity.key(a)] == 19 and counts[identity.key(b)] == 300)
  assert(counts[identity.key(fluid)] == 144000)
  w.items[identity.key(a)].tag = nil
  raises(function() hw:stock(rows) end, "NBT unavailable")
end)

local openos = require("openos")
local runtime = openos.install()
local configModule = require("meteor.config")
test("native-resolution T3 launch renders products and keeps menu interaction usable", function()
  local gpu = openos.gpu()
  gpu.setResolution(160, 50)
  gpu.setDepth(8)
  local ui = require("meteor.ui").new(gpu, configModule.defaults(), {recipes = {recipe}})
  ui:draw({mode = "stopped", state = "IDLE", rows = {{
    key = identity.key(product), product = product, stock = 0,
    policy = {target = 100, active = true, meteor = "iron", craft = false},
  }}})
  local frame = gpu.render()
  assert(frame:find("DASHBOARD", 1, true) and frame:find("0 items", 1, true))
  assert(frame:find("100 items", 1, true) and frame:find("iron", 1, true))
  ui:handle({"key_down", "keyboard", 109, 0})
  assert(gpu.render():find("Hardware setup", 1, true))
  ui:close()
  local width, height = gpu.getResolution()
  assert(width == 160 and height == 50 and gpu.getDepth() == 8)
end)
test("slot picker saves exact items and automatically registers contained fluid", function()
  local cfg = configModule.defaults()
  local w = world.new(cfg, recipe)
  local tagged = world.item("mod:metal", 2032, "\0\255iron")
  local cell = world.item("mod:cell", 1, "\0hidden")
  cell.tag = nil
  local fluid = {kind = "fluid", name = "molten.iron", label = "Molten Iron", hasTag = false}
  w.sampleSlots[0] = {[2] = {stack = tagged}, [3] = {stack = cell,
    fluid = {name = fluid.name, label = fluid.label, amount = 144}}}
  w.networkDown = true
  local hw = hardware.new(w.component, cfg)
  local path = "/etc/meteor/sample-picker.cfg"
  local ui = require("meteor.ui").new(openos.gpu(), cfg, {recipes = {recipe}}, {
    sampleProduct = function(side, slot) return hw:sampleProduct(side, slot) end,
    save = function() return configModule.save(path, cfg) end,
  })
  ui.pendingOre = {key = "OREDICT:oreIron", label = "Iron Ore"}
  ui:setScreen("mapping")
  ui:handle({"key_down", "keyboard", 13, 28})
  ui:handle({"key_down", "keyboard", 0, 208})
  ui:handle({"key_down", "keyboard", 13, 28})
  ui:handle({"key_down", "keyboard", 0, 14})
  ui:handle({"clipboard", "keyboard", "2"})
  ui:handle({"key_down", "keyboard", 13, 28})
  ui:handle({"key_down", "keyboard", 0, 208})
  ui:handle({"key_down", "keyboard", 0, 208})
  ui:handle({"key_down", "keyboard", 13, 28})
  assert(ui.screen == "mapping" and identity.same(cfg.oreProducts["OREDICT:oreIron"][1], tagged))
  ui:handle({"key_down", "keyboard", 97, 0})
  ui:handle({"touch", "screen", 5, 6, 0})
  ui:handle({"key_down", "keyboard", 0, 14})
  ui:handle({"clipboard", "keyboard", "3"})
  ui:handle({"key_down", "keyboard", 13, 28})
  ui:handle({"touch", "screen", 5, 7, 0})
  local saved = configModule.load(path).oreProducts["OREDICT:oreIron"]
  assert(#saved == 2 and identity.same(saved[1], tagged) and identity.same(saved[2], fluid))
  ui:handle({"key_down", "keyboard", 97, 0})
  ui.selected = 3
  ui:handle({"key_down", "keyboard", 13, 28})
  assert(ui.screen == "sampling" and #cfg.oreProducts["OREDICT:oreIron"] == 2)
  assert(#configModule.load(path).oreProducts["OREDICT:oreIron"] == 2)
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "mapping" and ui.pendingOre.key == "OREDICT:oreIron")
  ui:close()
end)

test("sample cancellation and active automation cannot change ore mappings", function()
  local cfg = configModule.defaults()
  local w = world.new(cfg, recipe)
  w.sampleSlots[0] = {[2] = {stack = product}}
  local hw = hardware.new(w.component, cfg)
  local ui = require("meteor.ui").new(openos.gpu(), cfg, {recipes = {recipe}}, {
    sampleProduct = function(side, slot) return hw:sampleProduct(side, slot) end,
  })
  ui.pendingOre = {key = "OREDICT:oreIron", label = "Iron Ore"}
  ui:setScreen("mapping")
  ui:handle({"key_down", "keyboard", 97, 0})
  ui:handle({"key_down", "keyboard", 13, 28})
  ui:handle({"key_down", "keyboard", 0, 14})
  ui:handle({"clipboard", "keyboard", "5"})
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "sampling" and ui.sampleSide == 0)
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "mapping" and cfg.oreProducts["OREDICT:oreIron"] == nil)
  ui:handle({"key_down", "keyboard", 97, 0})
  ui.sampleSlot = 2
  ui:draw({mode = "auto", state = "IDLE"})
  ui.selected = 3
  ui:handle({"key_down", "keyboard", 13, 28})
  assert(ui.screen == "sampling" and cfg.oreProducts["OREDICT:oreIron"] == nil)
  ui:close()
end)

test("failed sample save restores prior mappings and permits a clean retry", function()
  local cfg = configModule.defaults()
  cfg.oreProducts["OREDICT:oreIron"] = {product}
  local w = world.new(cfg, recipe)
  local nextProduct = world.item(product.name, product.damage, "\0new")
  w.sampleSlots[0] = {[2] = {stack = nextProduct}}
  local hw = hardware.new(w.component, cfg)
  local path = "/etc/meteor/sample-save-error.cfg"
  configModule.save(path, cfg)
  local ui = require("meteor.ui").new(openos.gpu(), cfg, {recipes = {recipe}}, {
    sampleProduct = function(side, slot) return hw:sampleProduct(side, slot) end,
    save = function() return configModule.save(path, cfg) end,
  })
  ui.pendingOre = {key = "OREDICT:oreIron", label = "Iron Ore"}
  ui:setScreen("mapping")
  ui:handle({"key_down", "keyboard", 97, 0})
  ui.sampleSlot, ui.selected = 2, 3
  runtime.fs.failFlushTo = path .. ".tmp"
  ui:handle({"key_down", "keyboard", 13, 28})
  runtime.fs.failFlushTo = nil
  assert(ui.screen == "sampling" and #cfg.oreProducts["OREDICT:oreIron"] == 1)
  assert(identity.same(cfg.oreProducts["OREDICT:oreIron"][1], product))
  assert(#configModule.load(path).oreProducts["OREDICT:oreIron"] == 1)
  ui:handle({"key_down", "keyboard", 13, 28})
  local saved = configModule.load(path).oreProducts["OREDICT:oreIron"]
  assert(ui.screen == "mapping" and #saved == 2 and identity.same(saved[2], nextProduct))
  ui:close()
end)


test("dashboard labels fit their columns without losing fitting characters", function()
  local gpu = openos.gpu()
  local ui = require("meteor.ui").new(gpu, configModule.defaults(), {recipes = {recipe}})
  local cases = {
    {label = "Iron Dust", damage = 2032, expected = "Iron Dust [2032]", meteor = "iron", expectedMeteor = "iron"},
    {label = string.rep("A", 56), expected = string.rep("A", 56) .. " [0]",
      meteor = string.rep("M", 33), expectedMeteor = string.rep("M", 33)},
    {label = string.rep("L", 65), expected = string.rep("L", 60),
      meteor = string.rep("N", 40), expectedMeteor = string.rep("N", 33)},
    {label = string.rep("A", 59) .. "𝄞", expected = string.rep("A", 59) .. "𝄞",
      meteor = "iron", expectedMeteor = "iron"},
    {label = string.rep("精", 29) .. "A精", expected = string.rep("精", 29) .. "A",
      meteor = "iron", expectedMeteor = "iron"},
  }
  for _, case in ipairs(cases) do
    local descriptor = world.item("mod:product", case.damage)
    descriptor.label = case.label
    ui:draw({mode = "stopped", state = "IDLE", rows = {{
      key = identity.key(descriptor), product = descriptor, stock = 987,
      policy = {target = 1000, active = true, meteor = case.meteor, craft = true},
    }}})
    local lines = {}
    for line in (gpu.render() .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    local rendered = openos.unicode.sub(lines[9], 4, 3 + openos.unicode.len(case.expected))
    assert(rendered == case.expected)
    local headerStart = assert(lines[7]:find("Current", 1, true))
    local stockStart = assert(lines[9]:find("987 items", 1, true))
    assert(openos.unicode.wlen(lines[7]:sub(1, headerStart - 1)) ==
      openos.unicode.wlen(lines[9]:sub(1, stockStart - 1)))
    assert(lines[9]:find(case.expectedMeteor .. string.rep(" ", 36 - #case.expectedMeteor) .. "yes", 1, true))
  end
  ui:close()
end)

test("Tab cancels edited values and quit confirmation without changing settings", function()
  local config = configModule.defaults()
  local reserve = config.reserveLP
  local ui = require("meteor.ui").new(openos.gpu(), config, {recipes = {recipe}})
  ui:setScreen("settings")
  ui:openPrompt("settings", "reserveLP", "1234", "number")
  ui:handle({"key_down", "keyboard", 0, 14})
  assert(ui.prompt.text == "123")
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "settings" and config.reserveLP == reserve)
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "menu")
  ui:handle({"key_down", "keyboard", 9, 15})
  ui:handle({"key_down", "keyboard", 113, 0})
  assert(ui.screen == "confirm")
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "home" and ui.confirmAction == nil and not ui.closed)
  ui:close()
end)

test("wiring cannot feed enable back as completion or mix routed inputs", function()
  local config = configModule.defaults()
  config.hardware.fillerInSide = config.hardware.fillerOutSide
  raises(function() configModule.validate(config) end, "completion input sides")
  config.hardware.fillerInSide = 2
  config.hardware.catalystSlot = config.hardware.focusSlot
  raises(function() configModule.validate(config) end, "catalyst slots")
end)
test("persistent metadata and binary NBT survive restart", function()
  local config = configModule.defaults()
  local tagged = world.item("mod:meta", 30000, "\0\255\1{tag}")
  config.oreProducts["ore"] = {tagged}
  config.policies[identity.key(tagged)] = {active = true, target = 20, meteor = "m", craft = false}
  configModule.save("/etc/meteor/config.cfg", config)
  local loaded = configModule.load("/etc/meteor/config.cfg")
  assert(identity.same(tagged, loaded.oreProducts.ore[1]))
  assert(loaded.policies[identity.key(tagged)].active)
end)
test("existing fluid policies survive registry-only sample registration", function()
  local cfg = configModule.defaults()
  local previous = {kind = "fluid", name = "molten.iron", label = "Molten Iron", hasTag = false}
  local storedKey = "5:fluid11:molten.iron0:0:N"
  cfg.oreProducts["OREDICT:oreIron"] = {previous}
  cfg.policies[storedKey] = {active = true, target = 14400, meteor = "iron", craft = true}
  configModule.save("/etc/meteor/fluid-policy.cfg", cfg)
  cfg = configModule.load("/etc/meteor/fluid-policy.cfg")
  local w = world.new(cfg, recipe)
  w.sampleSlots[0] = {[2] = {stack = world.item("mod:cell", 1, "\0contents"),
    fluid = {name = "molten.iron", amount = 1000}}}
  cfg.oreProducts["OREDICT:oreIron"][1] = hardware.new(w.component, cfg):sampleProduct(0, 2)
  configModule.save("/etc/meteor/fluid-policy.cfg", cfg)
  local rows = model.aggregate(configModule.load("/etc/meteor/fluid-policy.cfg"), {recipes = {recipe}})
  assert(#rows == 1 and rows[1].key == storedKey)
  assert(rows[1].policy.active and rows[1].policy.target == 14400 and rows[1].policy.craft)
  rows[1].stock = 1000
  local selected = model.choose(rows)
  assert(selected and selected.recipe == "iron" and selected.craft)
end)
test("failed config replacement preserves prior policies", function()
  local path = "/etc/meteor/config.cfg"
  local previous = configModule.load(path)
  local changed = configModule.load(path)
  changed.reserveLP = previous.reserveLP + 1
  runtime.fs.failRenameTo = path
  raises(function() configModule.save(path, changed) end)
  runtime.fs.failRenameTo = nil
  local restored = configModule.load(path)
  assert(restored.reserveLP == previous.reserveLP)
end)
test("failed config flush preserves the installed settings", function()
  local path = "/etc/meteor/flush-error.cfg"
  local config = configModule.defaults()
  config.reserveLP = 123456
  configModule.save(path, config)
  config.reserveLP = 654321
  runtime.fs.failFlushTo = path .. ".tmp"
  raises(function() configModule.save(path, config) end)
  runtime.fs.failFlushTo = nil
  assert(configModule.load(path).reserveLP == 123456)
end)
test("explicit close failure prevents config replacement", function()
  local path = "/etc/meteor/close-error.cfg"
  local config = configModule.defaults()
  config.reserveLP = 123456
  configModule.save(path, config)
  config.reserveLP = 654321
  runtime.fs.failCloseTo = path .. ".tmp"
  raises(function() configModule.save(path, config) end)
  runtime.fs.failCloseTo = nil
  assert(configModule.load(path).reserveLP == 123456)
end)

test("restart requires clearing journaled buffer slots before acknowledging recovery", function()
  local c, w, cfg, _, hw = setup()
  local path = "/etc/meteor/buffer-state"
  c.journal = require("meteor.journal").open(path)
  w.lp = 0
  c:run("iron", false)
  untilState(c, w, "LP")
  c:stop()
  local save, interrupted, record = require("meteor.journal").open(path)
  local restarted = controller.new(cfg, c.catalog, hw, function() return w.time end, save)
  restarted:boot(interrupted, record)
  tick(restarted, w, 10)
  assert(restarted.state == "FAULT" and #w.staged == 2 and #w.transfers == 0 and w.pulses == 0)
  raises(function() restarted:reset() end, "buffer slot")
  local _, stillDirty = require("meteor.journal").open(path)
  assert(stillDirty)
  w.buffer = {}
  restarted:reset()
  tick(restarted, w, 3)
  local _, clean = require("meteor.journal").open(path)
  assert(not clean and restarted.mode == "stopped" and w.pulses == 0)
  assert(w.proxies.tp.getStackInSlot(0, 1).ownerName == cfg.hardware.owner)
end)

test("journal restart latches dirty intent and clears on acknowledgement", function()
  local path = "/etc/meteor/state"
  local journal, dirty = require("meteor.journal").open(path)
  assert(not dirty)
  journal(true, "iron")
  local reloaded, interrupted = require("meteor.journal").open(path)
  assert(interrupted)
  reloaded(false)
  local _, clean = require("meteor.journal").open(path)
  assert(not clean)
  runtime.files[path .. ".tmp"] = "partial"
  local _, uncertain = require("meteor.journal").open(path)
  assert(uncertain)
end)
test("failed journal flush cannot clear interrupted-cycle intent", function()
  local path = "/etc/meteor/flush-error-state"
  local save = require("meteor.journal").open(path)
  save(true, "iron")
  runtime.fs.failFlushTo = path .. ".tmp"
  raises(function() save(false) end)
  runtime.fs.failFlushTo = nil
  local state = package.loaded.serialization.unserialize(runtime.files[path])
  assert(state.dirty and state.recipe == "iron")
  local _, interrupted = require("meteor.journal").open(path)
  assert(interrupted)
end)

runtime.restore()

print(string.format("%d behavioural tests passed", total))
