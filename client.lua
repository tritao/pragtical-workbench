local native_available, native = pcall(require, "workbench")
local next_runtime_operation = 0

local Client = {}
Client.__index = Client

function Client.open(options)
  options = options or {}
  if not native_available then
    return nil, "Workbench native support is disabled"
  end

  local ok, handle = pcall(native.open, {
    backend = options.backend or "fake",
    workspace = options.workspace or "default"
  })
  if not ok then
    return nil, handle
  end

  return setmetatable({
    handle = handle,
    backend = handle:backend(),
    workspace_id = handle:workspace()
  }, Client)
end

function Client:is_open()
  return self.handle ~= nil
end

function Client:snapshot()
  return self.handle:snapshot()
end

function Client:execute(command)
  return self.handle:execute(command)
end

function Client:on_event(callback)
  return self.handle:on_event(callback)
end

function Client:poll()
  return self.handle:poll()
end

function Client:write_runtime(runtime_id, data)
  if self.handle.write_runtime then return self.handle:write_runtime(runtime_id, data) end
  return true
end

function Client:resize_runtime(runtime_id, columns, rows)
  if self.handle.resize_runtime then
    return self.handle:resize_runtime(runtime_id, columns, rows)
  end
  next_runtime_operation = next_runtime_operation + 1
  local result = self:execute {
    type = "terminal.update",
    operation_id = "runtime-resize-" .. runtime_id .. "-" .. tostring(next_runtime_operation),
    terminal_id = runtime_id, cols = columns, rows = rows
  }
  return result.code == "ok", result
end

function Client:stop_runtime(runtime_id, options)
  if self.handle.stop_runtime then return self.handle:stop_runtime(runtime_id, options or {}) end
  next_runtime_operation = next_runtime_operation + 1
  local result = self:execute {
    type = "terminal.status",
    operation_id = "runtime-stop-" .. runtime_id .. "-" .. tostring(next_runtime_operation),
    terminal_id = runtime_id, status = "closed"
  }
  return result.code == "ok", result
end

function Client:detach_runtime(runtime_id)
  if self.handle.detach_runtime then return self.handle:detach_runtime(runtime_id) end
  return true
end

function Client:request_runtime_output(runtime_id, offset)
  if self.handle.request_runtime_output then
    return self.handle:request_runtime_output(runtime_id, offset)
  end
  return false, "runtime replay is not available"
end

function Client:poll_runtime_events(runtime_id)
  if self.handle.poll_runtime_events then return self.handle:poll_runtime_events(runtime_id) end
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
end

return Client
