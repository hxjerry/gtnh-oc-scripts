-- In-memory OpenOS boundary for host-side behavioural tests. Not an emulator.
local M = {}
local function quote(v)
  if type(v) == "string" then return string.format("%q", v) end
  if type(v) == "boolean" or type(v) == "number" then return tostring(v) end
  if type(v) == "nil" then return "nil" end
  assert(type(v) == "table", "cannot serialize " .. type(v))
  local parts = {}
  for k, child in pairs(v) do parts[#parts + 1] = "[" .. quote(k) .. "]=" .. quote(child) end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end
local function chars(text)
  local values = {}
  for char in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do values[#values + 1] = char end
  return values
end
local function codepoint(char)
  local a, b, c, d = char:byte(1, 4)
  if a < 128 then return a end
  if a < 224 then return (a - 192) * 64 + b - 128 end
  if a < 240 then return (a - 224) * 4096 + (b - 128) * 64 + c - 128 end
  return (a - 240) * 262144 + (b - 128) * 4096 + (c - 128) * 64 + d - 128
end
local function charWidth(char)
  local n = codepoint(char)
  return (n >= 0x4e00 and n <= 0x9fff) and 2 or 1
end
M.unicode = {
  len = function(text) return #chars(text) end,
  sub = function(text, first, last)
    local values = chars(text)
    if first < 0 then first = #values + first + 1 end
    last = last or #values
    if last < 0 then last = #values + last + 1 end
    local out = {}
    for i = math.max(1, first), math.min(#values, last) do out[#out + 1] = values[i] end
    return table.concat(out)
  end,
  wlen = function(text) local n = 0; for _, char in ipairs(chars(text)) do n = n + charWidth(char) end; return n end,
  wtrunc = function(text, width)
    local out, n = {}, 0
    for _, char in ipairs(chars(text)) do
      n = n + charWidth(char)
      if n > width then break end
      out[#out + 1] = char
    end
    return table.concat(out)
  end,
  char = function(n)
    if n < 128 then return string.char(n) end
    if n < 2048 then return string.char(192 + math.floor(n / 64), 128 + n % 64) end
    return string.char(224 + math.floor(n / 4096), 128 + math.floor(n / 64) % 64, 128 + n % 64)
  end,
}
function M.install()
  local files, directories = {}, {["/"] = true, ["/etc"] = true}
  local fs = {}
  function fs.path(path) return path:match("^(.*)/[^/]*$") or "." end
  function fs.exists(path) return files[path] ~= nil or directories[path:gsub("/$", "")] == true end
  function fs.makeDirectory(path)
    path = path:gsub("/$", "")
    if fs.exists(path) then return nil, "already exists" end
    directories[path] = true
    return true
  end
  function fs.isDirectory(path) return directories[path] == true end
  function fs.remove(path) files[path] = nil; directories[path] = nil; return true end
  function fs.rename(from, to)
    if fs.failRenameTo == to then return nil, "simulated rename failure" end
    if not files[from] then return nil, "missing source" end
    files[to], files[from] = files[from], nil
    return true
  end
  local oldOpen = io.open
  function io.open(path, mode)
    mode = mode or "r"
    local reading = mode:sub(1, 1) == "r"
    if reading and files[path] == nil then return nil, "not found" end
    if not reading and not directories[fs.path(path)] then return nil, "parent missing" end
    if not reading then files[path] = "" end
    local position, closed = 1, false
    return {
      read = function(_, count)
        assert(not closed)
        if count == "*a" then position = #files[path] + 1; return files[path] end
        assert(type(count) == "number")
        if position > #files[path] then return nil end
        local result = files[path]:sub(position, position + count - 1)
        position = position + #result
        return result
      end,
      write = function(self, text) assert(not closed); files[path] = files[path] .. text; return self end,
      close = function() closed = true; return true end,
    }
  end
  function fs.open(path, mode)
    local buffered, why = io.open(path, mode)
    if not buffered then return nil, why end
    local read = buffered.read
    buffered.read = function(self, count) assert(type(count) == "number", "raw filesystem.read needs a number"); return read(self, count) end
    return buffered
  end
  package.loaded.filesystem = fs
  package.loaded.serialization = {serialize = quote, unserialize = function(text)
    local chunk, reason = load("return " .. text, "=saved-data", "t", {})
    if not chunk then return nil, reason end
    local ok, value = pcall(chunk)
    if not ok then return nil, value end
    return value
  end}
  package.loaded.unicode = M.unicode
  return {files = files, fs = fs, restore = function() io.open = oldOpen end}
end
function M.gpu()
  local width, height, foreground, background, depth = 80, 25, 0xFFFFFF, 0, 4
  local grid, colors = {}, {}
  local function blank()
    grid = {}
    for y = 1, height do grid[y] = {}; for x = 1, width do grid[y][x] = " " end end
  end
  blank()
  local gpu = {
    getResolution = function() return width, height end,
    maxResolution = function() return 160, 50 end,
    setResolution = function(w, h) assert(w <= 160 and h <= 50); width, height = w, h; blank(); return true end,
    getForeground = function() return foreground, false end,
    getBackground = function() return background, false end,
    setForeground = function(c) foreground = c; colors[c] = true; return c end,
    setBackground = function(c) background = c; colors[c] = true; return c end,
    getDepth = function() return depth end, maxDepth = function() return 8 end,
    setDepth = function(d) assert(d == 4 or d == 8); depth = d; return true end,
    set = function(x, y, text)
      assert(x >= 1 and y >= 1 and y <= height and x + M.unicode.wlen(text) - 1 <= width, "GPU text overflow")
      assert(not text:find("\n", 1, true), "GPU does not support multiline set")
      for _, char in ipairs(chars(text)) do
        grid[y][x] = char; x = x + 1
        if charWidth(char) == 2 then grid[y][x] = ""; x = x + 1 end
      end
      return true
    end,
    fill = function(x, y, w, h, char)
      assert(x >= 1 and y >= 1 and x + w - 1 <= width and y + h - 1 <= height)
      for j = y, y + h - 1 do for i = x, x + w - 1 do grid[j][i] = char end end
      return true
    end,
  }
  function gpu.render()
    local lines = {}
    for y = 1, height do lines[y] = table.concat(grid[y]):gsub(" +$", "") end
    return table.concat(lines, "\n")
  end
  function gpu.colorCount() local n = 0; for _ in pairs(colors) do n = n + 1 end; return n end
  return gpu
end
return M
