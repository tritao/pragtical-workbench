-- A deliberately small MessagePack codec for Workbench control messages.
-- Workbench messages contain structured data and integers; terminal byte
-- streams use a separate native transport in the runtime layer.

local msgpack = {}

local MAX_DEPTH = 32
local MAX_ITEMS = 100000
local MAX_STRING = 16 * 1024 * 1024

local function byte(value)
  return string.char(value % 256)
end

local function u16(value)
  return byte(math.floor(value / 256)) .. byte(value)
end

local function u32(value)
  local a = math.floor(value / 16777216)
  value = value - a * 16777216
  local b = math.floor(value / 65536)
  value = value - b * 65536
  local c = math.floor(value / 256)
  return byte(a) .. byte(b) .. byte(c) .. byte(value)
end

local function u64(value)
  local bytes = {}
  for index = 8, 1, -1 do
    local high = math.floor(value / 256)
    bytes[index] = byte(value - high * 256)
    value = high
  end
  return table.concat(bytes)
end

local function i16(value)
  if value < 0 then value = value + 65536 end
  return u16(value)
end

local function i32(value)
  if value < 0 then value = value + 4294967296 end
  return u32(value)
end

local function array_shape(value)
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      return false, 0
    end
    count = count + 1
  end
  for index = 1, count do
    if value[index] == nil then return false, 0 end
  end
  return true, count
end

local function encode_value(value, depth, seen)
  if depth > MAX_DEPTH then error("MessagePack nesting limit exceeded") end
  local kind = type(value)
  if value == nil then return "\xc0" end
  if kind == "boolean" then return value and "\xc3" or "\xc2" end
  if kind == "string" then
    local length = #value
    if length > MAX_STRING then error("MessagePack string is too large") end
    if length < 32 then return byte(160 + length) .. value end
    if length < 256 then return "\xd9" .. byte(length) .. value end
    if length < 65536 then return "\xda" .. u16(length) .. value end
    return "\xdb" .. u32(length) .. value
  end
  if kind == "number" then
    if value ~= math.floor(value) then
      error("Workbench MessagePack values must use integer numbers")
    end
    if value >= 0 then
      if value < 128 then return byte(value) end
      if value < 256 then return "\xcc" .. byte(value) end
      if value < 65536 then return "\xcd" .. u16(value) end
      if value < 4294967296 then return "\xce" .. u32(value) end
      if value <= 9007199254740991 then return "\xcf" .. u64(value) end
    else
      if value >= -32 then return byte(256 + value) end
      if value >= -128 then return "\xd0" .. byte(value) end
      if value >= -32768 then return "\xd1" .. i16(value) end
      if value >= -2147483648 then return "\xd2" .. i32(value) end
      if value >= -9007199254740991 then return "\xd3" .. u64(value + 18446744073709551616) end
    end
    error("Workbench MessagePack integer is outside the safe range")
  end
  if kind ~= "table" then error("unsupported MessagePack value: " .. kind) end
  if seen[value] then error("cyclic MessagePack value") end
  seen[value] = true

  local is_array, count = array_shape(value)
  if is_array then
    if count < 16 then
      local result = { byte(144 + count) }
      for index = 1, count do
        result[#result + 1] = encode_value(value[index], depth + 1, seen)
      end
      seen[value] = nil
      return table.concat(result)
    end
    local result = { count < 65536 and "\xdc" .. u16(count) or "\xdd" .. u32(count) }
    for index = 1, count do
      result[#result + 1] = encode_value(value[index], depth + 1, seen)
    end
    seen[value] = nil
    return table.concat(result)
  end

  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      error("Workbench MessagePack maps require string keys")
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local result
  if #keys < 16 then
    result = { byte(128 + #keys) }
  elseif #keys < 65536 then
    result = { "\xde", u16(#keys) }
  else
    result = { "\xdf", u32(#keys) }
  end
  for _, key in ipairs(keys) do
    result[#result + 1] = encode_value(key, depth + 1, seen)
    result[#result + 1] = encode_value(value[key], depth + 1, seen)
  end
  seen[value] = nil
  return table.concat(result)
end

function msgpack.encode(value)
  return encode_value(value, 0, {})
end

local function need(data, position, length)
  if position + length - 1 > #data then
    error("truncated MessagePack value")
  end
end

local function read_byte(data, position)
  need(data, position, 1)
  return data:byte(position), position + 1
end

local function read_u16(data, position)
  need(data, position, 2)
  return data:byte(position) * 256 + data:byte(position + 1), position + 2
end

local function read_u32(data, position)
  need(data, position, 4)
  return data:byte(position) * 16777216
    + data:byte(position + 1) * 65536
    + data:byte(position + 2) * 256
    + data:byte(position + 3), position + 4
end

local function read_u64(data, position)
  need(data, position, 8)
  local value = 0
  for index = 0, 7 do
    value = value * 256 + data:byte(position + index)
  end
  return value, position + 8
end

local function decode_value(data, position, depth, count)
  if depth > MAX_DEPTH then error("MessagePack nesting limit exceeded") end
  count = count + 1
  if count > MAX_ITEMS then error("MessagePack item limit exceeded") end
  local marker
  marker, position = read_byte(data, position)

  if marker <= 0x7f then return marker, position end
  if marker >= 0xe0 then return marker - 256, position end
  if marker == 0xc0 then return nil, position end
  if marker == 0xc2 then return false, position end
  if marker == 0xc3 then return true, position end
  if marker >= 0xa0 and marker <= 0xbf then
    local length = marker - 0xa0
    need(data, position, length)
    return data:sub(position, position + length - 1), position + length
  end
  if marker >= 0x90 and marker <= 0x9f then
    local result = {}
    for index = 1, marker - 0x90 do
      result[index], position = decode_value(data, position, depth + 1, count)
    end
    return result, position
  end
  if marker >= 0x80 and marker <= 0x8f then
    local result = {}
    for _ = 1, marker - 0x80 do
      local key, value
      key, position = decode_value(data, position, depth + 1, count)
      value, position = decode_value(data, position, depth + 1, count)
      if type(key) ~= "string" then error("MessagePack map key is not a string") end
      result[key] = value
    end
    return result, position
  end

  local length
  if marker == 0xcc then return read_byte(data, position) end
  if marker == 0xcd then return read_u16(data, position) end
  if marker == 0xce then return read_u32(data, position) end
  if marker == 0xcf then return read_u64(data, position) end
  if marker == 0xd0 then
    local value
    value, position = read_byte(data, position)
    return value >= 128 and value - 256 or value, position
  end
  if marker == 0xd1 then
    local value
    value, position = read_u16(data, position)
    return value >= 32768 and value - 65536 or value, position
  end
  if marker == 0xd2 then
    local value
    value, position = read_u32(data, position)
    return value >= 2147483648 and value - 4294967296 or value, position
  end
  if marker == 0xd3 then
    local value
    value, position = read_u64(data, position)
    return value, position
  end
  if marker == 0xd9 then length, position = read_byte(data, position)
  elseif marker == 0xda then length, position = read_u16(data, position)
  elseif marker == 0xdb then length, position = read_u32(data, position)
  end
  if length then
    if length > MAX_STRING then error("MessagePack string is too large") end
    need(data, position, length)
    return data:sub(position, position + length - 1), position + length
  end

  local items
  if marker == 0xdc then items, position = read_u16(data, position)
  elseif marker == 0xdd then items, position = read_u32(data, position) end
  if items then
    if items > MAX_ITEMS then error("MessagePack array is too large") end
    local result = {}
    for index = 1, items do
      result[index], position = decode_value(data, position, depth + 1, count)
    end
    return result, position
  end

  if marker == 0xde then items, position = read_u16(data, position)
  elseif marker == 0xdf then items, position = read_u32(data, position) end
  if items then
    if items > MAX_ITEMS then error("MessagePack map is too large") end
    local result = {}
    for _ = 1, items do
      local key, value
      key, position = decode_value(data, position, depth + 1, count)
      value, position = decode_value(data, position, depth + 1, count)
      if type(key) ~= "string" then error("MessagePack map key is not a string") end
      result[key] = value
    end
    return result, position
  end
  error(string.format("unsupported MessagePack marker 0x%02x", marker))
end

function msgpack.decode(data, position)
  if type(data) ~= "string" then error("MessagePack input must be a string") end
  local value, next_position = decode_value(data, position or 1, 0, 0)
  return value, next_position
end

return msgpack
