local terminal = require "plugins.terminal"

local WorkbenchSession = {}
WorkbenchSession.__index = WorkbenchSession
local next_operation = 0

local function operation_id(resource_id, suffix)
  next_operation = next_operation + 1
  return "pragtical-terminal-" .. resource_id .. "-" .. tostring(next_operation)
    .. (suffix and "-" .. suffix or "")
end

local function call_runtime(client, method, runtime_id, ...)
  local implementation = client[method]
  if type(implementation) == "function" then
    return implementation(client, runtime_id, ...)
  end
  if method == "resize_runtime" then
    local columns, rows = ...
    local result = client:execute {
      type = "terminal.update", operation_id = operation_id(runtime_id, "resize"),
      terminal_id = runtime_id, cols = columns, rows = rows
    }
    return result.code == "ok", result
  elseif method == "stop_runtime" then
    local result = client:execute {
      type = "terminal.status", operation_id = operation_id(runtime_id, "stop"),
      terminal_id = runtime_id, status = "closed"
    }
    return result.code == "ok", result
  elseif method == "detach_runtime" then
    return true
  elseif method == "request_runtime_output" then
    return false, "runtime replay is not available"
  elseif method == "poll_runtime_events" or method == "write_runtime" then
    return method == "poll_runtime_events" and {} or true
  end
end

function WorkbenchSession.new(client, resource, options)
  options = options or {}
  resource = resource or {}
  local resource_id = assert(options.runtime_id or resource.runtime_id or resource.id,
    "Workbench terminal resource requires an id")
  local emulator = options.emulator or terminal.new_emulator {
    columns = resource.cols or 80, rows = resource.rows or 24,
    scrollback_limit = options.scrollback_limit or 10000
  }
  local self = setmetatable({
    client = client, resource = resource, resource_id = resource_id,
    emulator = emulator, status_name = resource.status or "starting"
  }, WorkbenchSession)
  self.session = terminal.Session {
    id = resource_id, status = self.status_name, emulator = emulator,
    capabilities = { persistent = true, replay = true, remote = true },
    write = function(_, data) return call_runtime(client, "write_runtime", resource_id, data) end,
    resize = function(_, columns, rows)
      emulator:resize(columns, rows)
      return call_runtime(client, "resize_runtime", resource_id, columns, rows)
    end,
    terminate = function(_, terminate_options)
      local result = call_runtime(client, "stop_runtime", resource_id, terminate_options or {})
      self.status_name = "closed"
      self.session:set_status("closed")
      return result
    end,
    request_replay = function(_, offset)
      return call_runtime(client, "request_runtime_output", resource_id, offset)
    end,
    detach = function() return call_runtime(client, "detach_runtime", resource_id) end,
    close = function() return self.session:terminate() end,
    poll_events = function() return self:poll_events() end
  }
  return self.session
end

function WorkbenchSession:poll_events()
  local events = call_runtime(self.client, "poll_runtime_events", self.resource_id) or {}
  for _, event in ipairs(events) do
    if event.type == "status" and event.status then
      self.status_name = event.status
      self.session:set_status(event.status)
    end
  end
  return events
end

return setmetatable(WorkbenchSession, {
  __call = function(_, client, resource, options)
    return WorkbenchSession.new(client, resource, options)
  end
})
