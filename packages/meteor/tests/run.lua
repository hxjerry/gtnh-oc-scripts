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
    function(dirty, id) journal.dirty, journal.recipe = dirty, id end)
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
    if c.state == state then return end
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

test("low LP blocks both transfer and activation", function()
  local c, w = setup()
  w.lp = 2199999
  c:run("iron", false)
  tick(c, w, 3)
  assert(c.state == "LP" and #w.transfers == 0 and w.pulses == 0)
  w.lp = 2200000
  tick(c, w, 1)
  assert(#w.transfers == 1)
end)

test("wrong orb owner faults closed", function()
  local c, w = setup()
  w.owner = "SomeoneElse"
  c:run("iron", false)
  tick(c, w)
  assert(c.state == "FAULT" and w.pulses == 0 and #w.transfers == 0)
end)

test("missing stock never autocrafts without policy permission", function()
  local c, w = setup({catalyst = false})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  tick(c, w, 12)
  assert(c.state == "FAULT" and w.requests == 0 and w.pulses == 0)
end)

test("autocraft waits for one exact requested input", function()
  local c, w = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  untilState(c, w, "IDLE")
  assert(w.requests == 1 and w.pulses == 1)
end)

test("canceled crafting cannot be retried into a ritual", function()
  local c, w = setup({catalyst = false, craft = true})
  w.stock[identity.key(recipe.focus)] = 0
  c:run("iron", false)
  tick(c, w, 0.4)
  assert(w.jobs[1]); w.jobs[1].canceled = true
  tick(c, w, 10)
  assert(c.state == "FAULT" and w.requests == 1 and w.pulses == 0)
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

test("transfer followed by clear failure never duplicates input", function()
  local c, w = setup({catalyst = false})
  w.failClear = true
  c:run("iron", false)
  tick(c, w, 5)
  assert(c.state == "FAULT" and #w.transfers == 1 and w.pulses == 0)
end)

test("non-callable ME fields cannot masquerade as required callbacks", function()
  local _, w, cfg = setup()
  w.proxies.me.getItemsInNetwork = {}
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
  assert(c.state == "LP")
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

test("ME search matches both product kinds without merging metadata or NBT variants", function()
  local _, w, _, _, hw = setup()
  local a, b = world.item("mod:metal", 7, "\0a"), world.item("mod:metal", 7, "\0b")
  a.label, b.label = "Iron Dust", "Iron Dust"
  w:add(a, 3); w:add(b, 4)
  local fluid = {kind = "fluid", name = "molten.iron", label = "Molten Iron", hasTag = false}
  w.fluids = {{name = fluid.name, label = fluid.label, hasTag = false, amount = 144}}
  local bad = world.item("mod:broken", 0, "\0hidden")
  bad.label = "Iron with hidden NBT"
  w:add(bad, 1); w.items[identity.key(bad)].tag = nil
  local rows, info = hw:searchProducts("  IRON  ")
  local keys = {}
  for _, row in ipairs(rows) do keys[identity.key(row)] = true end
  assert(#rows == 3 and keys[identity.key(a)] and keys[identity.key(b)] and keys[identity.key(fluid)])
  assert(info.skipped == 1 and info.firstError:find("NBT unavailable", 1, true))
  assert(not info.itemTruncated and not info.fluidTruncated)
  rows = hw:searchProducts("molten.iron")
  assert(#rows == 1 and identity.same(rows[1], fluid))
  rows = hw:searchProducts("Iron.*")
  assert(#rows == 0) -- User input is literal, never a Lua pattern.
end)

test("ME search caps each kind and stops consuming the item stream at the limit", function()
  local _, w, _, _, hw = setup()
  w.proxies.me.getItemsInNetwork = function() error("Bulk items exceed OC RAM") end
  w.proxies.me.allItems = function()
    local index = 0
    return setmetatable({}, {__call = function()
      index = index + 1
      assert(index <= 1051, "Search consumed an unbounded item stream")
      local stack = world.item("mod:meta", index, "\0exact" .. index)
      stack.label = index <= 1000 and "Unrelated Ore" or "Iron Dust"
      return stack
    end})
  end
  for index = 1, 50 do
    w.fluids[index] = {name = "molten.iron." .. index, label = "Iron Fluid " .. index, hasTag = false, amount = 144}
  end
  local rows, info = hw:searchProducts("iron")
  local counts = {item = 0, fluid = 0}
  for _, row in ipairs(rows) do
    counts[row.kind] = counts[row.kind] + 1
    if row.kind == "item" then assert(row.tag == "\0exact" .. row.damage) end
  end
  assert(counts.item == 50 and counts.fluid == 50 and #rows == 100)
  assert(info.itemTruncated and not info.fluidTruncated and info.skipped == 0)
  w.fluids[51] = {name = "molten.iron.51", label = "Iron Fluid 51", hasTag = false, amount = 144}
  rows, info = hw:searchProducts("iron")
  assert(#rows == 100 and info.itemTruncated and info.fluidTruncated)
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

test("product picker requires a term and saves items and fluids from one shared search", function()
  local cfg = configModule.defaults()
  local cat = {recipes = {recipe}}
  local w = world.new(cfg, recipe)
  local tagged = world.item("mod:metal", 2032, "\0\255iron")
  tagged.label = "Iron Dust"
  w:add(tagged, 3)
  local fluid = {kind = "fluid", name = "molten.iron", label = "Molten Iron", hasTag = false}
  w.fluids = {{name = fluid.name, label = fluid.label, hasTag = false, amount = 144}}
  local hw = hardware.new(w.component, cfg):connect()
  local gpu = openos.gpu()
  local path = "/etc/meteor/search-picker.cfg"
  local ui = require("meteor.ui").new(gpu, cfg, cat, {
    searchProducts = function(query, pause) return hw:searchProducts(query, pause) end,
    save = function() configModule.save(path, cfg); return true end,
  })
  ui.pendingOre = {key = "OREDICT:oreIron", label = "Iron Ore"}
  ui:setScreen("mapping")
  w.networkDown = true
  ui:handle({"key_down", "keyboard", 13, 28})
  assert(ui.screen == "prompt" and gpu.render():find("SEARCH ME PRODUCTS", 1, true))
  ui:handle({"clipboard", "keyboard", "   "})
  ui:handle({"key_down", "keyboard", 13, 28})
  assert(ui.screen == "prompt" and ui.message:find("nonblank", 1, true))
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "mapping")
  w.networkDown = false
  ui:handle({"key_down", "keyboard", 97, 0})
  ui:handle({"clipboard", "keyboard", "IRON"})
  ui:handle({"key_down", "keyboard", 13, 28})
  ui:tickSearch(); ui:draw()
  assert(ui.screen == "browse" and #ui:entries() == 2)
  assert(gpu.render():find("Iron Dust", 1, true) and gpu.render():find("Molten Iron", 1, true))
  for _, desired in ipairs({tagged, fluid}) do
    if ui.screen == "mapping" then
      ui:handle({"key_down", "keyboard", 97, 0})
      assert(ui.prompt.text == "IRON")
      ui:handle({"key_down", "keyboard", 13, 28})
      ui:tickSearch()
    end
    for index, row in ipairs(ui.browseRows) do if identity.same(row, desired) then ui.selected = index end end
    ui:handle({"key_down", "keyboard", 13, 28})
    assert(ui.screen == "mapping" and ui.browseRows == nil)
  end
  local saved = configModule.load(path).oreProducts["OREDICT:oreIron"]
  assert(#saved == 2 and identity.same(saved[1], tagged) and identity.same(saved[2], fluid))
  ui:close()
end)

test("ME search can be canceled and failed replacement searches cannot expose stale products", function()
  local cfg = configModule.defaults()
  local w = world.new(cfg, recipe)
  local target = world.item("mod:iron", 1)
  w:add(target, 5)
  local hw = hardware.new(w.component, cfg):connect()
  local ui = require("meteor.ui").new(openos.gpu(), cfg, {recipes = {recipe}}, {
    searchProducts = function(query, pause) return hw:searchProducts(query, pause) end,
  })
  ui.pendingOre = {key = "OREDICT:oreIron", label = "Iron Ore"}
  ui:setScreen("mapping"); ui:beginProductSearch()
  ui:handle({"clipboard", "keyboard", "iron"})
  ui:handle({"key_down", "keyboard", 13, 28}); ui:tickSearch()
  assert(ui.screen == "browse" and identity.same(ui.browseRows[1], target))
  ui:handle({"key_down", "keyboard", 47, 0})
  ui:handle({"key_down", "keyboard", 9, 15})
  assert(ui.screen == "browse" and identity.same(ui.browseRows[1], target))
  ui:handle({"key_down", "keyboard", 47, 0})
  w.networkDown = true
  ui:handle({"key_down", "keyboard", 13, 28}); ui:tickSearch()
  assert(ui.screen == "prompt" and ui.browseRows == nil and ui.message:find("ME disconnected", 1, true))
  ui:handle({"key_down", "keyboard", 9, 15})
  w.networkDown = false
  local consumed = 0
  w.proxies.me.allItems = function()
    return setmetatable({}, {__call = function()
      consumed = consumed + 1
      return world.item("mod:unrelated", consumed)
    end})
  end
  ui:beginProductSearch()
  ui:handle({"key_down", "keyboard", 13, 28}); ui:tickSearch(); ui:draw()
  assert(ui.screen == "searching" and consumed > 0 and consumed < 100)
  assert(ui.gpu.render():find("Tab cancels", 1, true))
  local stoppedAt = consumed
  ui:handle({"key_down", "keyboard", 9, 15}); ui:tickSearch()
  assert(ui.screen == "mapping" and consumed == stoppedAt and ui.browseRows == nil)
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
