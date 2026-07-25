local native_available, native = pcall(require, "workbench")
local Service = require "plugins.workbench.service"

local next_operation = 0
local services = {}

local Client = {}
Client.__index = Client

local function next_id(prefix)
  next_operation = next_operation + 1
  return prefix .. "-" .. tostring(next_operation)
end

local function copy_command(client, command)
  local result = {}
  for key, value in pairs(command or {}) do result[key] = value end
  result.workspace_id = result.workspace_id or client.workspace_id
  if result.expected_revision == nil and client.service then
    result.expected_revision = client:snapshot().revision
  end
  result.operation_id = result.operation_id or result.id or next_id("workbench-operation")
  return result
end

function Client.open(options)
  options = options or {}
  local backend = options.backend or "fake"
  local workspace_id = options.workspace_id or options.workspace or "default"

  if backend == "fake" or backend == "in_process" then
    local service = services[workspace_id]
    if not service then
      service = Service.new { workspace_id = workspace_id }
      services[workspace_id] = service
    end
    return setmetatable({
      service = service,
      backend = backend,
      workspace_id = workspace_id,
      closed = false,
    }, Client)
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
  return not self.closed and (self.service ~= nil or self.handle ~= nil)
end

function Client:snapshot()
  if self.service then return self.service:snapshot() end
  return self.handle:snapshot()
end

function Client:execute(command)
  if self.closed then
    return { code = "closed", message = "Workbench client is closed" }
  end
  command = copy_command(self, command)
  if self.service then return self.service:execute(command) end
  return self.handle:execute(command)
end

function Client:on_event(callback)
  if self.service then return self.service:subscribe(callback) end
  return self.handle:on_event(callback)
end

function Client:poll()
  if self.service then return self.service:poll() end
  return self.handle:poll()
end

function Client:write_runtime(runtime_id, data)
  if self.handle and self.handle.write_runtime then
    return self.handle:write_runtime(runtime_id, data)
  end
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
  return true
end

function Client:request_runtime_output(runtime_id, offset)
  if self.handle and self.handle.request_runtime_output then
    return self.handle:request_runtime_output(runtime_id, offset)
  end
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
  if self.handle then
    self.handle:close()
    self.handle = nil
  end
  self.closed = true
end

return Client
