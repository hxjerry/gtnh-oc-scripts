local M = {}
function M.main(args)
  args = args or {}
  if args[1] == "--help" then
    print("meteor [--config /etc/meteor/config.cfg]")
    print("Tier III screen/GPU required. Configure hardware and ore products in the TUI.")
    print("Ritual pulse must drive a bound-crystal activator, NOT the Master Ritual Stone.")
    return true
  end
  assert(#args == 0 or (#args == 2 and args[1] == "--config"), "Usage: meteor [--config PATH]")
  local component, event, computer = require("component"), require("event"), require("computer")
  local configModule, model = require("meteor.config"), require("meteor.model")
  local catalog = require("meteor.catalog")
  local path = args[2] or "/etc/meteor/config.cfg"
  local config = configModule.load(path)
  configModule.validate(config)
  model.validate(config, catalog)
  local journal, interrupted = require("meteor.journal").open(path .. ".journal")
  local hardware = require("meteor.hardware").new(component, config)
  local controller = require("meteor.controller").new(config, catalog, hardware, computer.uptime, journal)
  local connected, running, ui = false, true
  local function connect()
    if connected then return end
    hardware:connect()
    connected = true
    controller:boot(interrupted)
    interrupted = false
  end
  local callbacks = {}
  function callbacks.save()
    assert(controller.state == "IDLE" or controller.state == "FAULT", "Stop before editing configuration")
    assert(controller.mode == "stopped", "Stop automation before editing configuration")
    configModule.validate(config)
    model.validate(config, catalog)
    local ok, err = hardware:safe()
    assert(ok, err)
    configModule.save(path, config)
    -- Recreate bindings so emergency shutdown always addresses the old wiring first.
    hardware = require("meteor.hardware").new(component, config)
    controller.hw, connected = hardware, false
    controller.rows = model.aggregate(config, catalog)
    controller.nextStock = 0
    controller:log("Configuration saved")
    return true
  end
  function callbacks.discover() return hardware:discover() end
  function callbacks.sampleProduct(side, slot)
    assert(controller.state == "IDLE" or controller.state == "FAULT", "Stop before sampling products")
    assert(controller.mode == "stopped", "Stop automation before sampling products")
    return hardware:sampleProduct(side, slot)
  end
  function callbacks.run(id, loop)
    connect()
    local ok, err = pcall(controller.run, controller, id, loop)
    if not ok then controller:fault(err); error(err, 0) end
  end
  function callbacks.auto()
    connect()
    controller:auto()
  end
  function callbacks.stop() controller:stop() end
  function callbacks.reset()
    connect()
    controller:reset()
  end
  function callbacks.shutdown()
    controller:stop()
    running = false
  end
  local function run()
    ui = require("meteor.ui").new(component.gpu, config, catalog, callbacks)
    local ok, err = pcall(connect)
    if not ok then
      controller:log("Setup needed: " .. tostring(err))
      local safe, reason = hardware:safe()
      if not safe then controller:fault(reason) end
    end
    local nextDraw = 0
    while running do
      local signal = {event.pull(0.1)}
      if signal[1] == "interrupted" then callbacks.shutdown()
      else
        controller:event(signal)
        if connected then
          local tickOK, tickError = pcall(controller.tick, controller)
          if not tickOK then controller:fault(tickError) end
        end
        if signal[1] then ui:handle(signal) end
      end
      if computer.uptime() >= nextDraw or signal[1] then
        ui:draw(controller:view())
        nextDraw = computer.uptime() + 1
      end
    end
  end
  local ok, err = xpcall(run, debug.traceback)
  if not ok then controller:fault(err) end
  local safe, reason = hardware:safe()
  if ui then
    local closed, closeError = pcall(ui.close, ui)
    if not closed then io.stderr:write("Screen restore failed: " .. tostring(closeError) .. "\n") end
  end
  if not ok then io.stderr:write(tostring(err) .. "\n") end
  if not safe then io.stderr:write("EMERGENCY: manually turn outputs OFF: " .. reason .. "\n") end
  return ok and safe
end
return M
