local common = require "core.common"

local codec = {}

function codec.encode(value)
  return common.serialize(value, { sort = true, limit = 64 })
end

function codec.decode(value)
  if value == nil then return nil end
  local chunk, message
  if loadstring then
    chunk, message = loadstring("return " .. value, "workbench-storage")
    if chunk and setfenv then setfenv(chunk, {}) end
  else
    chunk, message = load("return " .. value, "workbench-storage", "t", {})
  end
  if not chunk then return nil, message end
  local ok, result = pcall(chunk)
  if not ok then return nil, result end
  return result
end

return codec
