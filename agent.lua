local common = require "core.common"
local Protocol = require "plugins.workbench.service.protocol"
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"
local transport = require "workbench_transport"

local Agent = {}

local function send(connection, message)
  return connection:send(Protocol.encode(message))
end

local function error_message(request_id, code, message)
  return Protocol.request("error", request_id, {
    error = { code = code, message = message },
  })
end

local function event_offset(service, event)
  if event.offset ~= nil then return event.offset end
  for index, current in ipairs(service.events) do
    if current == event then return service.event_offset + index - 1 end
  end
  return service.event_offset + #service.events
end

local function run_client(service, connection, options)
  local workspace_id = service.workspace_id
  local subscribed = false
  local pending_events = {}
  local unsubscribe

  local function queue_event(event)
    if subscribed then
      pending_events[#pending_events + 1] = {
        event = event,
        offset = event_offset(service, event),
      }
    end
  end

  local function flush_events()
    while #pending_events > 0 do
      local item = table.remove(pending_events, 1)
      local ok, message = send(connection, Protocol.request("event", nil, item))
      if not ok then return nil, message end
    end
    return true
  end

  while true do
    local frame, receive_message = connection:receive(-1)
    if not frame then return true end
    local message, decode_message = Protocol.decode(frame)
    if not message then
      send(connection, error_message(nil, "invalid_protocol", decode_message))
    elseif message.kind == "close" then
      break
    elseif message.kind == "hello" then
      if message.workspace_id and message.workspace_id ~= workspace_id then
        send(connection, error_message(message.request_id, "workspace_mismatch",
          "requested workspace does not match the agent workspace"))
      else
        send(connection, Protocol.request("hello_result", message.request_id, {
          ok = true,
          workspace_id = workspace_id,
          revision = service.revision,
          capabilities = {
            event_replay = true,
            sqlite = true,
            runtimes = false,
          },
        }))
      end
    elseif message.kind == "snapshot" then
      send(connection, Protocol.request("snapshot", message.request_id, {
        snapshot = service:snapshot(),
      }))
    elseif message.kind == "subscribe" then
      if unsubscribe then unsubscribe() end
      subscribed = true
      unsubscribe = service:subscribe(queue_event)
      local events, replay_error = service:get_events(message.offset or 0)
      if events then
        for index, event in ipairs(events) do
          local ok, send_message = send(connection, Protocol.request("event", nil, {
            event = event,
            offset = (message.offset or 0) + index - 1,
          }))
          if not ok then return nil, send_message end
        end
      else
        local ok, send_message = send(connection, Protocol.request("snapshot", message.request_id, {
          reason = replay_error,
          snapshot = service:snapshot(),
        }))
        if not ok then return nil, send_message end
      end
      local ok, send_message = send(connection, Protocol.request("subscribed", message.request_id, {
        revision = service.revision,
        offset = service.event_offset + #service.events,
      }))
      if not ok then return nil, send_message end
    elseif message.kind == "command" then
      if type(message.command) ~= "table" then
        send(connection, error_message(message.request_id, "invalid_command", "command is required"))
      else
        local result = service:execute(message.command)
        local ok, send_message = send(connection, Protocol.request("result", message.request_id, {
          result = result,
        }))
        if not ok then return nil, send_message end
        if subscribed then
          local flushed, flush_message = flush_events()
          if not flushed then return nil, flush_message end
        end
      end
    else
      send(connection, error_message(message.request_id, "unsupported_message",
        "message is not valid in the current agent session"))
    end
  end

  if unsubscribe then unsubscribe() end
  return true
end

function Agent.run(options)
  options = options or {}
  assert(type(options.endpoint) == "string", "Workbench agent endpoint is required")
  assert(type(options.storage_path) == "string", "Workbench agent storage path is required")
  local directory = options.endpoint:match("^(.+)[/\\][^/\\]+$")
  if directory then common.mkdirp(directory) end

  local store, message = Storage.new(options.storage_path, {
    event_limit = options.event_limit,
  })
  assert(store, message)
  local service = Service.new {
    workspace_id = options.workspace_id or "default",
    store = store,
    event_limit = options.event_limit,
  }
  local server, listen_message = transport.listen(options.endpoint)
  assert(server, listen_message)

  repeat
    local connection, accept_message = server:accept()
    if connection then
      run_client(service, connection, options)
      connection:close()
    else
      server:close()
      service:close()
      error(accept_message)
    end
  until options.once

  server:close()
  service:close()
  return true
end

return Agent
