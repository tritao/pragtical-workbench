local terminal = require "plugins.terminal"
local config = require "core.config"
local LocalSession = require "plugins.terminal.local_backend"

local WorkbenchSession = {}
WorkbenchSession.__index = WorkbenchSession
local next_operation = 0

local function operation_id(resource_id, suffix)
  next_operation = next_operation + 1
  return "pragtical-terminal-" .. resource_id .. "-" .. tostring(next_operation)
    .. (suffix and "-" .. suffix or "")
end

local function call_runtime(client, method, runtime_id, ...)
  local asynchronous = client[method .. "_async"]
  if type(asynchronous) == "function" then
    return asynchronous(client, runtime_id, ...)
  end
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
      terminal_id = runtime_id, status = "stopped"
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

local function resource_config(resource)
  return resource.config or resource.options or {}
end

local function local_options(client, resource, options, resource_id)
  if client.service and client.service.providers then
    local runtime_options, message = client.service.providers:runtime_spec(resource, options, {
      workspace_id = client.workspace_id,
    })
    if not runtime_options then
      error(message and (message.message or message.code) or "provider rejected runtime")
    end
    runtime_options.id = resource_id
    runtime_options.terminate_on_detach = false
    return runtime_options
  end
  local configured = resource_config(resource)
  local terminal_config = config.plugins and config.plugins.terminal or {}
  local shell = options.shell or configured.shell or configured.command

  if not shell then
    shell = terminal_config.shell or os.getenv("SHELL") or "sh"
  end

  return {
    id = resource_id,
    command = shell,
    args = options.args or configured.args or configured.arguments,
    cwd = options.cwd or configured.cwd,
    environment = options.environment or configured.environment or configured.env,
    columns = options.columns or resource.cols or 80,
    rows = options.rows or resource.rows or 24,
    term = options.term or configured.term or "xterm-256color",
    scrollback_limit = options.scrollback_limit or configured.scrollback_limit or 10000,
    terminate_on_detach = false,
  }
end

local function local_status(local_session)
  local status = local_session:status()
  return status == "closed" and "stopped" or status
end

function WorkbenchSession:_persist_status(status)
  if self.status_name == status then
    return true
  end

  self.status_name = status
  self.session:set_status(status)

  if not self.client or type(self.client.execute) ~= "function" then
    return true
  end

  local result = self.client:execute {
    type = "terminal.status",
    operation_id = operation_id(self.resource_id, "status"),
    terminal_id = self.resource_id,
    status = status,
  }
  return result and result.code == "ok", result
end

function WorkbenchSession:_local_events()
  local events = self.local_session:poll_events() or {}
  for _, event in ipairs(events) do
    if event.type == "status" and event.status then
      self:_persist_status(event.status)
    end
  end
  return events
end

function WorkbenchSession.new(client, resource, options)
  options = options or {}
  resource = resource or {}
  local resource_id = assert(options.runtime_id or resource.runtime_id or resource.id,
    "Workbench terminal resource requires an id")
  if client.backend == "fake" or client.backend == "in_process" then
    local local_session = LocalSession(local_options(client, resource, options, resource_id))
    local self = setmetatable({
      client = client, resource = resource, resource_id = resource_id,
      local_session = local_session, emulator = local_session.emulator,
      status_name = local_status(local_session)
    }, WorkbenchSession)

    self.session = terminal.Session {
      id = resource_id,
      status = self.status_name,
      emulator = self.emulator,
      capabilities = {
        local_process = true,
        persistent = true,
        replay = false,
        events_applied = false,
      },
      write = function(_, data)
        return local_session:write(data)
      end,
      resize = function(_, columns, rows)
        return local_session:resize(columns, rows)
      end,
      terminate = function(_, terminate_options)
        local result, message = local_session:terminate(terminate_options or {})
        self:_persist_status(local_status(local_session))
        return result, message
      end,
      request_replay = function()
        return false, "local runtime replay is not available"
      end,
      detach = function()
        return local_session:detach()
      end,
      close = function()
        local result, message = local_session:close()
        self:_persist_status(local_status(local_session))
        return result, message
      end,
      poll_events = function()
        return self:_local_events()
      end,
    }
    self:_persist_status(self.status_name)
    return self.session
  end

  local emulator = options.emulator or terminal.new_emulator {
    columns = options.columns or resource.cols or 80,
    rows = options.rows or resource.rows or 24,
    scrollback_limit = options.scrollback_limit or 10000,
    term = options.term,
    environment = options.environment,
    debug = options.debug,
  }
  local self = setmetatable({
    client = client, resource = resource, resource_id = resource_id,
    emulator = emulator, status_name = resource.status or "starting"
  }, WorkbenchSession)

  local function request_replay(session, offset)
    -- A bounded history can legitimately lose the requested prefix between
    -- detaching and reattaching. Retry from the advertised boundary; the
    -- agent may include a checkpoint there, followed by the retained bytes.
    if client.connection and type(client.request_runtime_output_async) == "function" then
      return client:request_runtime_output_async(resource_id, offset, function(result,
          error_result)
        if error_result or type(result) ~= "table"
            or result.code ~= "runtime_history_gap" then
          return
        end
        local oldest_offset = result.oldest_offset
        if type(oldest_offset) == "number" and oldest_offset > offset
            and session:replay_pending() == offset then
          session:request_replay(oldest_offset)
        end
      end)
    end
    return call_runtime(client, "request_runtime_output", resource_id, offset)
  end

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
      self.status_name = "stopped"
      self.session:set_status("closed")
      return result
    end,
    request_replay = request_replay,
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
