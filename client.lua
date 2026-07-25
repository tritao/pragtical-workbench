local native_available, native = pcall(require, "workbench")
local transport_available, transport = pcall(require, "workbench_transport")
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"
local Protocol = require "plugins.workbench.service.protocol"

local next_operation = 0
local services = {}

local Client = {}
Client.__index = Client

local function next_id(prefix)
  next_operation = next_operation + 1
  return prefix .. "-" .. tostring(next_operation)
end

local function default_storage_path()
  if type(USERDIR) ~= "string" then return nil end
  return USERDIR .. PATHSEP .. "workbench.sqlite3"
end

local function copy_command(client, command)
  local result = {}
  for key, value in pairs(command or {}) do result[key] = value end
  result.workspace_id = result.workspace_id or client.workspace_id
  if result.expected_revision == nil and (client.service or client.agent_snapshot) then
    result.expected_revision = client:snapshot().revision
  end
  result.operation_id = result.operation_id or result.id or next_id("workbench-operation")
  return result
end

local function agent_error(code, message)
  return { code = code, message = message }
end

function Client:_agent_message(message, expected_kind)
  local ok, send_message = pcall(function()
    return self.connection:send(Protocol.encode(message))
  end)
  if not ok then return nil, send_message end
  while true do
    local frame, receive_message = self.connection:receive(-1)
    if not frame then
      return nil, agent_error("agent_disconnected", receive_message or "agent disconnected")
    end
    local response, decode_message = Protocol.decode(frame)
    if not response then
      return nil, agent_error("invalid_protocol", decode_message)
    end
    if response.kind == "error" and response.request_id == message.request_id then
      return nil, response.error or agent_error("agent_error", "agent rejected the request")
    end
    if response.kind == expected_kind and response.request_id == message.request_id then
      return response
    end
    self:_handle_agent_message(response)
  end
end

function Client:_handle_agent_message(message)
  if message.kind == "event" and message.event then
    if message.offset then self.agent_event_offset = message.offset + 1 end
    for _, callback in ipairs(self.agent_callbacks or {}) do
      pcall(callback, message.event)
    end
  elseif message.kind == "snapshot" and message.snapshot then
    self.agent_snapshot = message.snapshot
    self.agent_event_offset = message.snapshot.event_offset or self.agent_event_offset
  end
end

function Client:_agent_snapshot()
  local response, message = self:_agent_message(Protocol.request("snapshot",
    next_id("workbench-snapshot"), {}), "snapshot")
  if not response then return nil, message end
  self:_handle_agent_message(response)
  return self.agent_snapshot
end

function Client:_agent_execute(command)
  local response, message = self:_agent_message(Protocol.request("command",
    next_id("workbench-request"), { command = command }), "result")
  if not response then
    if type(message) == "table" then
      return agent_error(message.code, message.message)
    end
    return agent_error("agent_error", tostring(message))
  end
  local result = response.result or agent_error("invalid_response", "agent returned no result")
  if result.code == "ok" then
    local snapshot = self:_agent_snapshot()
    if not snapshot then
      return agent_error("agent_disconnected", "agent did not return a snapshot")
    end
  end
  return result
end

function Client.open(options)
  options = options or {}
  local backend = options.backend or "fake"
  local workspace_id = options.workspace_id or options.workspace or "default"

  if backend == "fake" or backend == "in_process" then
    local storage_path = options.storage_path
    if backend == "in_process" and storage_path == nil then
      storage_path = default_storage_path()
    end
    local key = workspace_id .. "\0" .. tostring(storage_path or "memory")
    local entry = services[key]
    if not entry then
      local store, message
      if storage_path then
        store, message = Storage.new(storage_path, {
          event_limit = options.event_limit,
        })
        if not store then return nil, message end
      end
      local ok, service = pcall(Service.new, {
        workspace_id = workspace_id,
        store = store,
        event_limit = options.event_limit,
      })
      if not ok then
        if store then store:close() end
        return nil, service
      end
      entry = { service = service, clients = 0, key = key }
      services[key] = entry
    end
    entry.clients = entry.clients + 1
    return setmetatable({
      service = entry.service,
      service_entry = entry,
      backend = backend,
      workspace_id = workspace_id,
      storage_path = storage_path,
      event_limit = options.event_limit,
      closed = false,
    }, Client)
  end

  if backend == "agent" then
    if not transport_available then
      return nil, "Workbench agent transport is disabled"
    end
    local endpoint = options.endpoint
    if type(endpoint) ~= "string" or endpoint == "" then
      return nil, "Workbench agent endpoint is required"
    end
    local connected, connection = pcall(transport.connect, endpoint)
    if not connected then return nil, connection end
    if not connection then return nil, "Unable to connect to Workbench agent" end
    local client = setmetatable({
      connection = connection,
      backend = backend,
      workspace_id = workspace_id,
      closed = false,
      agent_callbacks = {},
      agent_event_offset = 0,
    }, Client)
    local hello, message = client:_agent_message(Protocol.request("hello",
      next_id("workbench-hello"), {
        workspace_id = workspace_id,
        capabilities = { event_replay = true },
      }), "hello_result")
    if not hello then
      connection:close()
      return nil, message and message.message or "Workbench agent handshake failed"
    end
    if not hello.ok then
      connection:close()
      return nil, hello.error and hello.error.message or "Workbench agent rejected the handshake"
    end
    client.agent_snapshot, message = client:_agent_snapshot()
    if not client.agent_snapshot then
      connection:close()
      return nil, message and message.message or "Workbench agent did not return a snapshot"
    end
    return client
  end

  if backend ~= "native" then
    return nil, "Workbench backend is not available: " .. tostring(backend)
  end
  if not native_available then
    return nil, "Workbench native support is disabled"
  end

  local ok, handle = pcall(native.open, {
    backend = "in_process",
    workspace = workspace_id,
  })
  if not ok then return nil, handle end
  return setmetatable({
    handle = handle,
    backend = backend,
    workspace_id = workspace_id,
    closed = false,
  }, Client)
end

function Client:is_open()
  return not self.closed and (self.service ~= nil or self.handle ~= nil or self.connection ~= nil)
end

function Client:snapshot()
  if self.service then return self.service:snapshot() end
  if self.connection then return self.agent_snapshot end
  return self.handle:snapshot()
end

function Client:execute(command)
  if self.closed then
    return { code = "closed", message = "Workbench client is closed" }
  end
  command = copy_command(self, command)
  if self.service then return self.service:execute(command) end
  if self.connection then return self:_agent_execute(command) end
  return self.handle:execute(command)
end

function Client:on_event(callback)
  if self.service then return self.service:subscribe(callback) end
  if self.connection then
    self.agent_callbacks[#self.agent_callbacks + 1] = callback
    if not self.agent_subscribed then
      self.agent_subscribed = true
      local response, message = self:_agent_message(Protocol.request("subscribe",
        next_id("workbench-subscribe"), {
          workspace_id = self.workspace_id,
          offset = self.agent_event_offset,
        }), "subscribed")
      if not response then
        self.agent_subscribed = false
        return nil, message
      end
    end
    local active = true
    return function()
      if not active then return end
      active = false
      for index, current in ipairs(self.agent_callbacks) do
        if current == callback then
          table.remove(self.agent_callbacks, index)
          break
        end
      end
    end
  end
  return self.handle:on_event(callback)
end

function Client:poll()
  if self.service then return self.service:poll() end
  if self.connection then
    local count = 0
    while true do
      local frame, message = self.connection:receive(0)
      if not frame then return count, message end
      local response, decode_message = Protocol.decode(frame)
      if not response then return count, decode_message end
      self:_handle_agent_message(response)
      count = count + 1
    end
  end
  return self.handle:poll()
end

function Client:write_runtime(runtime_id, data)
  if self.handle and self.handle.write_runtime then
    return self.handle:write_runtime(runtime_id, data)
  end
  if self.connection then return false, "agent runtimes are not available yet" end
  return true
end

function Client:resize_runtime(runtime_id, columns, rows)
  if self.handle and self.handle.resize_runtime then
    return self.handle:resize_runtime(runtime_id, columns, rows)
  end
  local result = self:execute {
    type = "terminal.update",
    operation_id = next_id("runtime-resize-" .. runtime_id),
    terminal_id = runtime_id,
    cols = columns,
    rows = rows,
  }
  return result.code == "ok", result
end

function Client:stop_runtime(runtime_id, options)
  if self.handle and self.handle.stop_runtime then
    return self.handle:stop_runtime(runtime_id, options or {})
  end
  local result = self:execute {
    type = "terminal.status",
    operation_id = next_id("runtime-stop-" .. runtime_id),
    terminal_id = runtime_id,
    status = "closed",
  }
  return result.code == "ok", result
end

function Client:detach_runtime(runtime_id)
  if self.handle and self.handle.detach_runtime then
    return self.handle:detach_runtime(runtime_id)
  end
  if self.connection then return false, "agent runtimes are not available yet" end
  return true
end

function Client:request_runtime_output(runtime_id, offset)
  if self.handle and self.handle.request_runtime_output then
    return self.handle:request_runtime_output(runtime_id, offset)
  end
  if self.connection then return false, "agent runtime replay is not available yet" end
  return false, "runtime replay is not available"
end

function Client:poll_runtime_events(runtime_id)
  if self.handle and self.handle.poll_runtime_events then
    return self.handle:poll_runtime_events(runtime_id)
  end
  return {}
end

function Client:terminal_session(resource_id, options)
  local snapshot = self:snapshot()
  for _, resource in ipairs(snapshot.terminals or {}) do
    if resource.id == resource_id then
      local WorkbenchSession = require "plugins.workbench.terminal_session"
      return WorkbenchSession(self, resource, options)
    end
  end
  return nil, "Workbench terminal resource not found: " .. tostring(resource_id)
end

function Client:close()
  if self.connection then
    pcall(function()
      self.connection:send(Protocol.encode(Protocol.request("close", nil, {})))
    end)
    self.connection:close()
    self.connection = nil
  end
  if self.handle then
    self.handle:close()
    self.handle = nil
  end
  if self.service_entry then
    self.service_entry.clients = self.service_entry.clients - 1
    if self.service_entry.clients <= 0 then
      self.service_entry.service:close()
      services[self.service_entry.key] = nil
    end
    self.service_entry = nil
  end
  self.closed = true
end

return Client
