local common = require "core.common"
local Protocol = require "plugins.workbench.service.protocol"
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"
local transport = require "workbench_transport"
local runtime_native = require "workbench_runtime"

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

local function safe_id(value)
  return tostring(value):gsub("[^%w_.-]", "_")
end

local function timestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function history_size(path)
  local file, message = io.open(path, "ab")
  if not file then return nil, message end
  local size = file:seek("end") or 0
  file:close()
  return size
end

local function append_history(path, data)
  local file, message = io.open(path, "ab")
  if not file then return nil, message end
  local ok, write_message = file:write(data)
  file:close()
  if not ok then return nil, write_message end
  return true
end

local function read_history(path, offset)
  local file, message = io.open(path, "rb")
  if not file then return nil, message end
  local size = file:seek("end") or 0
  if offset > size then
    file:close()
    return nil, "runtime replay offset is beyond the available history"
  end
  file:seek("set", offset)
  local data = file:read(64 * 1024) or ""
  file:close()
  return data, size
end

local function runtime_state(runtimes, runtime_id)
  return runtimes[runtime_id]
end

local function queue_runtime_event(state, event)
  state.pending[#state.pending + 1] = event
  while #state.pending > 512 do
    table.remove(state.pending, 1)
  end
end

local function service_error(service, command, code, message)
  return service:_error(code, message, command.operation_id)
end

local function preflight(service, command)
  local operation_id = command.operation_id or command.id
  local previous = operation_id and service.operations[operation_id]
  if previous then return previous end
  if command.workspace_id and command.workspace_id ~= service.workspace_id then
    return service_error(service, command, "workspace_mismatch",
      "command workspace does not match client workspace")
  end
  if command.expected_revision ~= nil and command.expected_revision ~= service.revision then
    return service_error(service, command, "revision_conflict",
      "expected revision " .. tostring(command.expected_revision)
      .. ", current revision is " .. tostring(service.revision))
  end
end

local function runtime_options(resource, command)
  local config = resource.config or {}
  local shell = command.shell or command.command or config.shell or config.command
    or os.getenv("SHELL") or "sh"
  return {
    command = shell,
    shell = shell,
    args = command.args or command.arguments or config.args or config.arguments,
    cwd = command.cwd or config.cwd,
    environment = command.environment or config.environment or config.env,
    columns = command.columns or command.cols or resource.cols or config.columns or 80,
    rows = command.rows or resource.rows or config.rows or 24,
    scrollback_limit = command.scrollback_limit or config.scrollback_limit or 10000,
    term = command.term or config.term or "xterm-256color",
  }
end

local function start_runtime(service, runtimes, history_directory, command)
  local previous = preflight(service, command)
  if previous then return previous end

  local resource_id = command.resource_id or command.terminal_id or command.runtime_id
  local resource = resource_id and service.resources[resource_id]
  if not resource then
    return service_error(service, command, "not_found",
      "resource not found: " .. tostring(resource_id))
  end
  local runtime_id = command.runtime_id or resource_id
  local current = runtime_state(runtimes, runtime_id)
  if current and current.runtime then
    return {
      code = "ok", operation_id = command.operation_id,
      revision = service.revision, runtime_id = runtime_id,
    }
  end

  local persisted = service.runtimes[runtime_id] or {}
  local history_path = persisted.history_path
    or (history_directory .. "/" .. safe_id(runtime_id) .. ".log")
  local offset, history_message = history_size(history_path)
  if not offset then
    return service_error(service, command, "storage_error", history_message)
  end

  local ok, native_or_message = pcall(runtime_native.new, runtime_options(resource, command))
  if not ok then
    return service_error(service, command, "runtime_error", tostring(native_or_message))
  end
  if not native_or_message then
    return service_error(service, command, "runtime_error", "failed to create runtime")
  end

  local state = current or {
    id = runtime_id,
    resource_id = resource_id,
    pending = {},
  }
  state.runtime = native_or_message
  state.resource_id = resource_id
  state.history_path = history_path
  state.offset = offset
  state.output_bytes = offset
  state.started_at = timestamp()
  runtimes[runtime_id] = state

  local result = service:execute {
    type = "runtime.update",
    operation_id = command.operation_id,
    workspace_id = command.workspace_id,
    expected_revision = command.expected_revision,
    runtime = {
      id = runtime_id,
      resource_id = resource_id,
      status = "running",
      started_at = state.started_at,
      output_bytes = state.output_bytes,
      output_offset = state.offset,
      history_path = history_path,
      metadata = { shell = runtime_options(resource, command).command },
    },
  }
  if result.code ~= "ok" then
    pcall(function() state.runtime:close() end)
    state.runtime = nil
    return result
  end
  return result
end

local function stop_runtime(service, runtimes, command)
  local previous = preflight(service, command)
  if previous then return previous end
  local runtime_id = command.runtime_id or command.resource_id or command.terminal_id
  local state = runtime_state(runtimes, runtime_id)
  if state and state.runtime then
    pcall(function() state.runtime:close() end)
    state.runtime = nil
  end
  local result = service:execute {
    type = "runtime.update",
    operation_id = command.operation_id,
    workspace_id = command.workspace_id,
    expected_revision = command.expected_revision,
    runtime = {
      id = runtime_id,
      resource_id = command.resource_id or command.terminal_id or runtime_id,
      status = "closed",
      ended_at = timestamp(),
      output_bytes = state and state.output_bytes or nil,
      output_offset = state and state.offset or nil,
    },
  }
  return result
end

local function resize_runtime(runtimes, command)
  local state = runtime_state(runtimes, command.runtime_id)
  if not state or not state.runtime then
    return { code = "runtime_not_running", message = "runtime is not running" }
  end
  local ok, message = pcall(function()
    state.runtime:resize(command.columns or command.cols, command.rows)
  end)
  if not ok then return { code = "runtime_error", message = tostring(message) } end
  return { code = "ok", runtime_id = command.runtime_id }
end

local function input_runtime(runtimes, command)
  local state = runtime_state(runtimes, command.runtime_id)
  if not state or not state.runtime then
    return { code = "runtime_not_running", message = "runtime is not running" }
  end
  local ok, written = pcall(function()
    return state.runtime:write(command.data or "")
  end)
  if not ok then return { code = "runtime_error", message = tostring(written) } end
  return { code = "ok", runtime_id = command.runtime_id, written = written }
end

local function replay_runtime(service, runtimes, command)
  local state = runtime_state(runtimes, command.runtime_id)
  local persisted = service.runtimes[command.runtime_id]
  local path = state and state.history_path or persisted and persisted.history_path
  if not path then
    return { code = "runtime_not_found", message = "runtime history is not available" }
  end
  local offset = command.offset or 0
  local data, size = read_history(path, offset)
  if not data then return { code = "runtime_replay_error", message = size } end
  local events = {}
  if #data > 0 then
    events[1] = {
      type = "output", runtime_id = command.runtime_id,
      offset = offset, data = data,
    }
  end
  return { code = "ok", runtime_id = command.runtime_id,
    offset = offset, available = size, runtime_events = events }
end

local function finish_runtime(service, runtimes, runtime_id, state, exit_code, signal)
  if state.runtime then
    pcall(function() state.runtime:close() end)
    state.runtime = nil
  end
  queue_runtime_event(state, {
    type = "status", runtime_id = runtime_id, status = "exited",
    exit_code = exit_code, signal = signal, offset = state.offset,
  })
  service:execute {
    type = "runtime.update",
    operation_id = "agent-runtime-status-" .. safe_id(runtime_id) .. "-"
      .. tostring(service.revision + 1) .. "-" .. tostring(state.offset),
    workspace_id = service.workspace_id,
    expected_revision = service.revision,
    runtime = {
      id = runtime_id,
      resource_id = state.resource_id,
      status = "exited",
      ended_at = timestamp(),
      output_bytes = state.output_bytes,
      output_offset = state.offset,
      history_path = state.history_path,
    },
  }
end

local function poll_runtimes(service, runtimes)
  for runtime_id, state in pairs(runtimes) do
    if state.runtime then
      local ok, data = pcall(function() return state.runtime:poll() end)
      if ok and type(data) == "string" and #data > 0 then
        local written, message = append_history(state.history_path, data)
        if written then
          local offset = state.offset
          state.offset = offset + #data
          state.output_bytes = state.offset
          queue_runtime_event(state, {
            type = "output", runtime_id = runtime_id,
            offset = offset, data = data,
          })
        else
          queue_runtime_event(state, {
            type = "status", runtime_id = runtime_id, status = "error",
            message = message, offset = state.offset,
          })
        end
      end
      local exited_ok, exited, exit_code, signal = pcall(function()
        return state.runtime:exited()
      end)
      if exited_ok and exited ~= false and exited ~= nil then
        finish_runtime(service, runtimes, runtime_id, state, exit_code, signal)
      end
    end
  end
end

local function event_message(item)
  return Protocol.request("event", nil, {
    event = item.event,
    offset = item.offset,
  })
end

local function run_client(service, connection, options, runtimes, history_directory)
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
      local ok, message = send(connection, event_message(item))
      if not ok then return nil, message end
    end
    for _, state in pairs(runtimes) do
      while #state.pending > 0 do
        local event = table.remove(state.pending, 1)
        local ok, message = send(connection, Protocol.request("event", nil, {
          event = event, offset = event.offset,
        }))
        if not ok then return nil, message end
      end
    end
    return true
  end

  local function tick()
    poll_runtimes(service, runtimes)
    return flush_events()
  end

  while true do
    local frame, receive_message = connection:receive(50)
    if not frame then
      if receive_message == "timeout" then
        local ok, message = tick()
        if not ok then return nil, message end
      else
        return true
      end
    else
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
              runtimes = true,
              runtime_replay = true,
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
      elseif message.kind == "batch" then
        if type(message.commands) ~= "table" then
          send(connection, error_message(message.request_id, "invalid_command", "commands are required"))
        else
          local result = service:execute_batch(message.commands)
          local ok, send_message = send(connection, Protocol.request("result", message.request_id, {
            result = result,
          }))
          if not ok then return nil, send_message end
          local flushed, flush_message = tick()
          if not flushed then return nil, flush_message end
        end
      elseif message.kind == "command" then
        if type(message.command) ~= "table" then
          send(connection, error_message(message.request_id, "invalid_command", "command is required"))
        else
          local command = message.command
          local result
          if command.type == "runtime.start" then
            result = start_runtime(service, runtimes, history_directory, command)
          elseif command.type == "runtime.restart" then
            local restart_state = runtimes[command.runtime_id or command.resource_id]
            if restart_state and restart_state.runtime then
              pcall(function() restart_state.runtime:close() end)
              restart_state.runtime = nil
            end
            result = start_runtime(service, runtimes, history_directory, command)
          elseif command.type == "runtime.stop" then
            result = stop_runtime(service, runtimes, command)
          elseif command.type == "runtime.input" then
            result = input_runtime(runtimes, command)
          elseif command.type == "runtime.resize" then
            result = resize_runtime(runtimes, command)
          elseif command.type == "runtime.replay" then
            result = replay_runtime(service, runtimes, command)
          else
            result = service:execute(command)
          end
          local ok, send_message = send(connection, Protocol.request("result", message.request_id, {
            result = result,
          }))
          if not ok then return nil, send_message end
          local flushed, flush_message = tick()
          if not flushed then return nil, flush_message end
        end
      else
        send(connection, error_message(message.request_id, "unsupported_message",
          "message is not valid in the current agent session"))
      end
      local flushed, flush_message = tick()
      if not flushed then return nil, flush_message end
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
  local history_directory = (options.data_dir or directory or ".") .. "/workbench-runtimes"
  local history_ok, history_message = common.mkdirp(history_directory)
  assert(history_ok, history_message)
  local runtimes = {}
  local server, listen_message = transport.listen(options.endpoint)
  assert(server, listen_message)

  local served = false
  while true do
    local connection, accept_message = server:accept(options.once and -1 or 50)
    if connection then
      served = true
      run_client(service, connection, options, runtimes, history_directory)
      connection:close()
      if options.once then break end
    elseif accept_message == "timeout" then
      poll_runtimes(service, runtimes)
    else
      server:close()
      service:close()
      error(accept_message)
    end
  end

  server:close()
  service:close()
  return served or not options.once
end

return Agent
