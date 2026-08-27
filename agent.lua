local common = require "core.common"
local Protocol = require "plugins.workbench.service.protocol"
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"
local transport = require "workbench_transport"
local runtime_native = require "workbench_runtime"

local Agent = {}

local function error_message(request_id, code, message)
  return Protocol.request("error", request_id, {
    error = { code = code, message = message },
  })
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

local function copy_table(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function ensure_operation_id(command, runtime_id, phase)
  local operation_id = command.operation_id or command.id
  if not operation_id then
    operation_id = "agent-runtime-" .. phase .. "-" .. safe_id(runtime_id)
    command.operation_id = operation_id
  end
  return operation_id
end

local function transition_operation_id(runtime_id, phase, revision)
  return "agent-runtime-" .. phase .. "-" .. safe_id(runtime_id)
    .. "-" .. tostring(revision)
end

local function runtime_transition(service, command, runtime_id, status, fields,
    operation_id, expected_revision)
  local existing = service.runtimes[runtime_id] or {}
  local runtime = {
    id = runtime_id,
    resource_id = fields and fields.resource_id or existing.resource_id,
    status = status,
  }
  for _, field in ipairs {
    "started_at", "ended_at", "output_bytes", "output_offset", "history_path",
    "pid", "metadata"
  } do
    if fields and fields[field] ~= nil then runtime[field] = fields[field] end
  end
  return service:execute {
    type = "runtime.update",
    operation_id = operation_id,
    workspace_id = service.workspace_id,
    expected_revision = expected_revision == nil and service.revision or expected_revision,
    runtime = runtime,
  }
end

local function runtime_failure_metadata(runtime, message)
  local metadata = {}
  for key, value in pairs(runtime and runtime.metadata or {}) do metadata[key] = value end
  metadata.error = tostring(message)
  return metadata
end

local function runtime_recovery_metadata(runtime, previous_status)
  local metadata = {}
  for key, value in pairs(runtime and runtime.metadata or {}) do metadata[key] = value end
  metadata.recovered_from = previous_status
  return metadata
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

local function start_runtime(service, runtimes, history_directory, command, skip_preflight)
  local resource_id = command.resource_id or command.terminal_id or command.runtime_id
  local runtime_id = command.runtime_id or resource_id
  local operation_id = ensure_operation_id(command, runtime_id, "start")
  local previous = not skip_preflight and preflight(service, command)
  if previous then return previous end

  local resource = resource_id and service.resources[resource_id]
  if not resource then
    return service_error(service, command, "not_found",
      "resource not found: " .. tostring(resource_id))
  end
  local current = runtime_state(runtimes, runtime_id)
  if current and current.runtime then
    return {
      code = "ok", operation_id = operation_id,
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

  local options = runtime_options(resource, command)
  local state = current or {
    id = runtime_id,
    resource_id = resource_id,
    pending = {},
  }
  state.resource_id = resource_id
  state.history_path = history_path
  state.offset = offset
  state.output_bytes = offset
  state.status = "starting"
  runtimes[runtime_id] = state

  local starting = runtime_transition(service, command, runtime_id, "starting", {
    resource_id = resource_id,
    output_bytes = offset,
    output_offset = offset,
    history_path = history_path,
    metadata = { shell = options.command },
  }, transition_operation_id(runtime_id, "starting", service.revision),
    command.expected_revision)
  if starting.code ~= "ok" then
    runtimes[runtime_id] = current
    return starting
  end

  local ok, native_or_message = pcall(runtime_native.new, options)
  if not ok then
    local message = tostring(native_or_message)
    local failed = runtime_transition(service, command, runtime_id, "failed", {
      resource_id = resource_id, ended_at = timestamp(), output_bytes = offset,
      output_offset = offset, history_path = history_path,
      metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
    }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
    state.status = failed.code == "ok" and "failed" or "starting"
    return service_error(service, command, "runtime_error", message)
  end
  if not native_or_message then
    local message = "failed to create runtime"
    local failed = runtime_transition(service, command, runtime_id, "failed", {
      resource_id = resource_id, ended_at = timestamp(), output_bytes = offset,
      output_offset = offset, history_path = history_path,
      metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
    }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
    state.status = failed.code == "ok" and "failed" or "starting"
    return service_error(service, command, "runtime_error", message)
  end

  state.runtime = native_or_message
  state.started_at = timestamp()
  local result = runtime_transition(service, command, runtime_id, "running", {
    resource_id = resource_id,
    started_at = state.started_at,
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = history_path,
    metadata = { shell = options.command },
  }, operation_id, service.revision)
  if result.code ~= "ok" then
    pcall(function() state.runtime:close() end)
    state.runtime = nil
    local failed = runtime_transition(service, command, runtime_id, "failed", {
      resource_id = resource_id, ended_at = timestamp(), output_bytes = offset,
      output_offset = offset, history_path = history_path,
      metadata = runtime_failure_metadata(service.runtimes[runtime_id], result.message),
    }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
    state.status = failed.code == "ok" and "failed" or "starting"
    return result
  end
  state.status = "running"
  return result
end

local function stop_runtime(service, runtimes, command, skip_preflight)
  local runtime_id = command.runtime_id or command.resource_id or command.terminal_id
  local operation_id = ensure_operation_id(command, runtime_id, "stop")
  local previous = not skip_preflight and preflight(service, command)
  if previous then return previous end
  local state = runtime_state(runtimes, runtime_id)
  local persisted = service.runtimes[runtime_id]
  if not state and not persisted then
    return service_error(service, command, "not_found",
      "runtime not found: " .. tostring(runtime_id))
  end
  if not state then
    state = {
      id = runtime_id,
      resource_id = persisted.resource_id,
      pending = {},
      history_path = persisted.history_path,
      offset = persisted.output_offset or 0,
      output_bytes = persisted.output_bytes or 0,
      status = persisted.status,
    }
    runtimes[runtime_id] = state
  end

  local stopping = runtime_transition(service, command, runtime_id, "stopping", {
    resource_id = state.resource_id,
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
  }, transition_operation_id(runtime_id, "stopping", service.revision),
    skip_preflight and service.revision or command.expected_revision)
  if stopping.code ~= "ok" then return stopping end
  state.status = "stopping"

  if state.runtime then
    local closed, close_message = pcall(function() return state.runtime:close() end)
    if not closed or close_message == false then
      state.status = "failed"
      local message = closed and "runtime close failed" or tostring(close_message)
      runtime_transition(service, command, runtime_id, "failed", {
        resource_id = state.resource_id, ended_at = timestamp(),
        output_bytes = state.output_bytes, output_offset = state.offset,
        history_path = state.history_path,
        metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
      }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
      return service_error(service, command, "runtime_error", message)
    end
    state.runtime = nil
  end

  local result = runtime_transition(service, command, runtime_id, "stopped", {
    resource_id = state.resource_id,
    ended_at = timestamp(),
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
  }, operation_id, service.revision)
  if result.code == "ok" then state.status = "stopped" end
  return result
end

local function restart_runtime(service, runtimes, history_directory, command)
  local operation_id = ensure_operation_id(command,
    command.runtime_id or command.resource_id or command.terminal_id, "restart")
  local previous = preflight(service, command)
  if previous then return previous end

  local stop_command = copy_table(command)
  stop_command.operation_id = transition_operation_id(
    command.runtime_id or command.resource_id or command.terminal_id, "restart-stop",
    service.revision)
  stop_command.expected_revision = service.revision
  local stopped = stop_runtime(service, runtimes, stop_command, true)
  if stopped.code ~= "ok" then return stopped end

  local start_command = copy_table(command)
  start_command.operation_id = operation_id
  start_command.expected_revision = service.revision
  return start_runtime(service, runtimes, history_directory, start_command, true)
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
  local result = runtime_transition(service, {}, runtime_id, "exited", {
    resource_id = state.resource_id,
    ended_at = timestamp(),
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
  }, transition_operation_id(runtime_id, "exited", service.revision), service.revision)
  if result.code == "ok" then
    state.status = "exited"
    queue_runtime_event(state, {
      type = "status", runtime_id = runtime_id, status = "exited",
      exit_code = exit_code, signal = signal, offset = state.offset,
    })
  else
    state.status = "interrupted"
  end
end

local function fail_runtime(service, runtime_id, state, message)
  if state.runtime then
    pcall(function() state.runtime:close() end)
    state.runtime = nil
  end
  local failed = runtime_transition(service, {}, runtime_id, "failed", {
    resource_id = state.resource_id,
    ended_at = timestamp(),
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
    metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
  }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
  if failed.code == "ok" then
    state.status = "failed"
    queue_runtime_event(state, {
      type = "status", runtime_id = runtime_id, status = "failed",
      message = message, offset = state.offset,
    })
  else
    state.status = "interrupted"
  end
  return failed
end

local function poll_runtimes(service, runtimes)
  for runtime_id, state in pairs(runtimes) do
    if state.runtime then
      local ok, data = pcall(function() return state.runtime:poll() end)
      if not ok then
        fail_runtime(service, runtime_id, state, tostring(data))
      else
        if type(data) == "string" and #data > 0 then
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
        elseif not exited_ok then
          fail_runtime(service, runtime_id, state, tostring(exited))
        end
      end
    end
  end
end

local MAX_MESSAGES_PER_CLIENT = 64
local MAX_OUTBOUND_MESSAGES = 1024
local MAX_OUTBOUND_BYTES = 8 * 1024 * 1024
local MAX_PENDING_EVENTS = 1024

local function event_message(event)
  return Protocol.request("event", nil, {
    event = event,
    event_sequence = event.event_sequence,
  })
end

local function new_client(connection)
  return {
    connection = connection,
    subscribed = false,
    pending_events = {},
    outgoing = {},
    outgoing_bytes = 0,
    write_pending = false,
    overloaded = false,
  }
end

local function enqueue(client, message)
  local ok, frame = pcall(Protocol.encode, message)
  if not ok then return nil, frame end
  if #client.outgoing >= MAX_OUTBOUND_MESSAGES
      or client.outgoing_bytes + #frame > MAX_OUTBOUND_BYTES then
    return nil, "Workbench client outbound queue limit exceeded"
  end
  client.outgoing[#client.outgoing + 1] = frame
  client.outgoing_bytes = client.outgoing_bytes + #frame
  return true
end

local function close_client(client)
  if client.unsubscribe then client.unsubscribe() end
  client.unsubscribe = nil
  client.closed = true
  pcall(function() client.connection:close() end)
end

local function queue_runtime_events(runtimes)
  local events = {}
  for _, state in pairs(runtimes) do
    while #state.pending > 0 do
      events[#events + 1] = table.remove(state.pending, 1)
    end
  end
  return events
end

local function handle_client_message(service, client, options, runtimes, history_directory,
    message)
  local workspace_id = service.workspace_id
  if message.kind == "close" then return false end

  if message.kind == "hello" then
    if message.workspace_id and message.workspace_id ~= workspace_id then
      return enqueue(client, error_message(message.request_id, "workspace_mismatch",
        "requested workspace does not match the agent workspace"))
    end
    return enqueue(client, Protocol.request("hello_result", message.request_id, {
      ok = true,
      workspace_id = workspace_id,
      revision = service.revision,
      capabilities = {
        event_replay = true,
        event_cursors = true,
        sqlite = true,
        runtimes = true,
        runtime_replay = true,
      },
    }))
  elseif message.kind == "snapshot" then
    return enqueue(client, Protocol.request("snapshot", message.request_id, {
      snapshot = service:snapshot(),
    }))
  elseif message.kind == "subscribe" then
    if client.unsubscribe then client.unsubscribe() end
    client.subscribed = true
    client.unsubscribe = service:subscribe(function(event)
      if client.subscribed and not client.closed then
        if #client.pending_events >= MAX_PENDING_EVENTS then
          client.overloaded = true
        else
          client.pending_events[#client.pending_events + 1] = event
        end
      end
    end)
    local events, replay_error = service:get_events(message.after_event_sequence or 0)
    if events then
      for _, event in ipairs(events) do
        local ok, send_message = enqueue(client, event_message(event))
        if not ok then return nil, send_message end
      end
    else
      local ok, send_message = enqueue(client, Protocol.request("snapshot", message.request_id, {
        reason = replay_error,
        snapshot = service:snapshot(),
      }))
      if not ok then return nil, send_message end
    end
    return enqueue(client, Protocol.request("subscribed", message.request_id, {
      revision = service.revision,
      event_cursor = service.event_sequence,
    }))
  elseif message.kind == "batch" then
    if type(message.commands) ~= "table" then
      return enqueue(client, error_message(message.request_id, "invalid_command",
        "commands are required"))
    end
    local result = service:execute_batch(message.commands)
    return enqueue(client, Protocol.request("result", message.request_id, {
      result = result,
    }))
  elseif message.kind == "command" then
    if type(message.command) ~= "table" then
      return enqueue(client, error_message(message.request_id, "invalid_command",
        "command is required"))
    end
    local command = message.command
    local result
    if command.type == "runtime.start" then
      result = start_runtime(service, runtimes, history_directory, command)
    elseif command.type == "runtime.restart" then
      result = restart_runtime(service, runtimes, history_directory, command)
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
    return enqueue(client, Protocol.request("result", message.request_id, {
      result = result,
    }))
  end

  return enqueue(client, error_message(message.request_id, "unsupported_message",
    "message is not valid in the current agent session"))
end

local function process_client(service, client, options, runtimes, history_directory)
  for _ = 1, MAX_MESSAGES_PER_CLIENT do
    local received, frame, receive_message = pcall(function()
      return client.connection:receive(0)
    end)
    if not received then return nil, frame end
    if not frame then
      if receive_message == "timeout" then return true end
      return nil, receive_message or "Workbench client disconnected"
    end

    local message, decode_message = Protocol.decode(frame)
    if not message then
      local ok, error_result = enqueue(client,
        error_message(nil, "invalid_protocol", decode_message))
      if not ok then return nil, error_result end
    else
      local ok, message_error = handle_client_message(service, client, options, runtimes,
        history_directory, message)
      if not ok then return nil, message_error or "client requested close" end
    end
  end
  return true
end

local function flush_client(client, runtime_events)
  if client.overloaded then return nil, "Workbench client event queue limit exceeded" end

  if client.write_pending then
    local called, flushed, flush_message = pcall(function()
      return client.connection:flush()
    end)
    if not called then return nil, flushed end
    if not flushed then
      if flush_message == "would_block" then return true end
      return nil, flush_message or "client send failed"
    end
    client.write_pending = false
  end

  while #client.pending_events > 0 do
    local event = table.remove(client.pending_events, 1)
    local ok, message = enqueue(client, event_message(event))
    if not ok then return nil, message end
  end
  for _, event in ipairs(runtime_events) do
    local ok, message = enqueue(client, Protocol.request("event", nil, {
      event = event, offset = event.offset,
    }))
    if not ok then return nil, message end
  end
  while #client.outgoing > 0 do
    local frame = client.outgoing[1]
    local called, sent, send_message = pcall(function()
      return client.connection:send_nonblocking(frame)
    end)
    if not called then return nil, sent end
    if sent then
      table.remove(client.outgoing, 1)
      client.outgoing_bytes = client.outgoing_bytes - #frame
    elseif send_message == "would_block" then
      -- The native transport owns the partially written frame now. Remove it
      -- from the Lua queue and let the next event-loop turn flush it.
      table.remove(client.outgoing, 1)
      client.outgoing_bytes = client.outgoing_bytes - #frame
      client.write_pending = true
      return true
    else
      return nil, send_message or "client send failed"
    end
  end
  return true
end

local function reconcile_runtimes(service, runtimes)
  for runtime_id, persisted in pairs(service.runtimes) do
    local state = {
      id = runtime_id,
      resource_id = persisted.resource_id,
      pending = {},
      history_path = persisted.history_path,
      offset = persisted.output_offset or 0,
      output_bytes = persisted.output_bytes or 0,
      status = persisted.status,
    }
    runtimes[runtime_id] = state

    if persisted.status == "starting" or persisted.status == "running"
        or persisted.status == "stopping" or persisted.status == "recovering" then
      local previous_status = persisted.status
      local result = runtime_transition(service, {}, runtime_id, "interrupted", {
        resource_id = persisted.resource_id,
        ended_at = timestamp(),
        output_bytes = state.output_bytes,
        output_offset = state.offset,
        history_path = state.history_path,
        metadata = runtime_recovery_metadata(persisted, previous_status),
      }, transition_operation_id(runtime_id, "recovery", service.revision),
        service.revision)
      assert(result.code == "ok", result.message)
      state.status = "interrupted"
    end
  end
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
  reconcile_runtimes(service, runtimes)
  local server, listen_message = transport.listen(options.endpoint)
  assert(server, listen_message)

  local served = false
  local clients = {}

  local function add_client(connection)
    served = true
    clients[#clients + 1] = new_client(connection)
  end

  local function remove_client(index)
    close_client(clients[index])
    table.remove(clients, index)
  end

  while true do
    if not (options.once and served) then
      local connection, accept_message = server:accept(options.once and -1 or 10)
      if connection then
        add_client(connection)
      elseif accept_message == "timeout" or accept_message == "unauthorized" then
        -- The shared event loop continues servicing existing clients below.
      else
        server:close()
        service:close()
        error(accept_message)
      end
    end

    if not options.once then
      while true do
        local extra, extra_message = server:accept(0)
        if extra then
          add_client(extra)
        elseif extra_message == "timeout" or extra_message == "unauthorized" then
          break
        else
          server:close()
          service:close()
          error(extra_message)
        end
      end
    end

    for index = #clients, 1, -1 do
      local client = clients[index]
      local ok = process_client(service, client, options, runtimes, history_directory)
      if not ok then remove_client(index) end
    end

    poll_runtimes(service, runtimes)
    local runtime_events = queue_runtime_events(runtimes)
    for index = #clients, 1, -1 do
      local ok = flush_client(clients[index], runtime_events)
      if not ok then remove_client(index) end
    end

    if options.once and served and #clients == 0 then break end
  end

  server:close()
  service:close()
  return served or not options.once
end

return Agent
