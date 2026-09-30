local args = {...}
local ok, err = pcall(function() return require("meteor.app").main(args) end)
if not ok then io.stderr:write("meteor: " .. tostring(err) .. "\n"); return false end
return err
