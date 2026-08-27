local MessagePack = require "plugins.workbench.service.msgpack"
local validation = require "plugins.workbench.service.validation"

local protocol = {
  version = 2,
  major = 2,
  minor = 1,
  max_message_size = 16 * 1024 * 1024,
}

local kinds = {
  hello = true,
  hello_result = true,
  command = true,
  batch = true,
  result = true,
  snapshot = true,
  subscribe = true,
  subscribed = true,
  event = true,
  error = true,
  close = true,
}

local required = {
  hello = { "request_id" },
  hello_result = { "request_id" },
  command = { "request_id", "command" },
  batch = { "request_id", "commands" },
  result = { "request_id", "result" },
  snapshot = { "request_id" },
  subscribe = { "request_id" },
  subscribed = { "request_id" },
  event = { "event" },
  error = { "error" },
}

local function valid_cursor(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function validate(message)
  if type(message) ~= "table" then return nil, "protocol message must be a map" end
  if message.protocol ~= protocol.version then
    return nil, "unsupported Workbench protocol version: " .. tostring(message.protocol)
  end
  for _, field in ipairs { "protocol_major", "protocol_minor" } do
    if message[field] ~= nil and not valid_cursor(message[field]) then
      return nil, "Workbench " .. field .. " must be a non-negative integer"
    end
  end
  if type(message.kind) ~= "string" or not kinds[message.kind] then
    return nil, "unknown Workbench protocol message kind"
  end
  for _, field in ipairs(required[message.kind] or {}) do
    if message[field] == nil then
      return nil, "missing required Workbench protocol field: " .. field
    end
  end
  if message.kind == "batch" and type(message.commands) ~= "table" then
    return nil, "Workbench batch commands must be a table"
  end
  if message.kind == "command" then
    local valid, validation_message = validation.command(message.command)
    if not valid then return nil, validation_message end
  elseif message.kind == "batch" then
    local valid, validation_message = validation.batch(message.commands)
    if not valid then return nil, validation_message end
  end
  if message.kind == "subscribe" and message.after_event_sequence ~= nil
      and not valid_cursor(message.after_event_sequence) then
    return nil, "Workbench event cursor must be a non-negative integer"
  end
  if message.kind == "event" and message.event_sequence ~= nil
      and not valid_cursor(message.event_sequence) then
    return nil, "Workbench event sequence must be a non-negative integer"
  end
  if message.kind == "subscribed" and message.event_cursor ~= nil
      and not valid_cursor(message.event_cursor) then
    return nil, "Workbench event cursor must be a non-negative integer"
  end
  if message.kind == "snapshot" and message.snapshot
      and message.snapshot.event_cursor ~= nil
      and not valid_cursor(message.snapshot.event_cursor) then
    return nil, "Workbench snapshot cursor must be a non-negative integer"
  end
  return true
end

function protocol.encode(message)
  assert(type(message) == "table", "Workbench protocol messages must be tables")
  assert(type(message.kind) == "string" and kinds[message.kind],
    "unknown Workbench protocol message kind")
  message.protocol = message.protocol or protocol.version
  local valid, message_error = validate(message)
  assert(valid, message_error)
  local frame = MessagePack.encode(message)
  assert(#frame <= protocol.max_message_size, "Workbench protocol message is too large")
  return frame
end

function protocol.decode(frame)
  if type(frame) ~= "string" then return nil, "protocol frame must be a string" end
  if #frame > protocol.max_message_size then return nil, "protocol frame is too large" end
  local ok, message, position = pcall(MessagePack.decode, frame)
  if not ok then return nil, message end
  if position ~= #frame + 1 then return nil, "protocol frame contains trailing data" end
  local valid, validation_message = validate(message)
  if not valid then return nil, validation_message end
  return message
end

function protocol.request(kind, request_id, fields)
  local message = {}
  for key, value in pairs(fields or {}) do message[key] = value end
  message.kind = kind
  message.request_id = request_id
  message.protocol = protocol.version
  return message
end

function protocol.compatibility(message)
  local major = message and message.protocol_major or protocol.major
  local minor = message and message.protocol_minor or 0
  if major ~= protocol.major then
    return nil, "unsupported Workbench protocol major version: " .. tostring(major)
  end
  return {
    major = protocol.major,
    minor = math.min(protocol.minor, minor),
  }
end

return protocol
