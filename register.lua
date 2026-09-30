-- Run on OpenOS after publishing this repository on GitHub's master branch.
local args = {...}
local repository = args[1]
assert(type(repository) == "string" and repository:match("^[%w_.%-]+/[%w_.%-]+$") and #args == 1,
  "Usage: register.lua owner/repository")
local internet, filesystem, serialization = require("internet"), require("filesystem"), require("serialization")
local response = assert(internet.request("https://raw.githubusercontent.com/" .. repository .. "/master/programs.cfg"))
local chunks = {}
for chunk in response do chunks[#chunks + 1] = chunk end
local packages, reason = serialization.unserialize(table.concat(chunks))
assert(type(packages) == "table" and type(packages.meteor) == "table" and type(packages.meteor.files) == "table",
  "Could not read OPPM package manifest: " .. tostring(reason))
local path, settings = "/etc/oppm.cfg", {path = "/usr", repos = {}}
if filesystem.exists(path) then
  local file = assert(io.open(path, "rb"))
  local text = file:read("*a")
  file:close()
  settings = assert(serialization.unserialize(text), "Invalid existing oppm.cfg; refusing to overwrite")
end
assert(type(settings.repos) == "table", "Existing oppm.cfg has no repos table")
settings.repos[repository] = packages
local tmp = path .. ".meteor.tmp"
local file = assert(io.open(tmp, "wb"))
assert(file:write(serialization.serialize(settings)))
assert(file:close())
assert(filesystem.rename(tmp, path), "Could not save OPPM settings; original retained")
print("Registered " .. repository .. ". Run: oppm install meteor")
