local common = require "core.common"
local validation = require "plugins.workbench.service.validation"
local Protocol = require "plugins.workbench.service.protocol"
local MessagePack = require "plugins.workbench.service.msgpack"
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"
local transport = require "workbench_transport"
local runtime_native = require "workbench_runtime"

local terminal_emulator
local terminal_emulator_load_error
do
  local loaded, module = pcall(require, "workbench_emulator")
  if loaded then
    terminal_emulator = module
  else
    terminal_emulator_load_error = tostring(module)
  end
end

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

local DEFAULT_MAX_HISTORY_BYTES = 16 * 1024 * 1024
local DEFAULT_CHECKPOINT_INTERVAL_BYTES = 256 * 1024
-- Checkpoints are returned in replay responses. Keep them comfortably below
-- the 8 MiB per-client outbound queue so a large terminal cannot turn a
-- replay request into a client disconnect.
local MAX_CHECKPOINT_BYTES = 4 * 1024 * 1024

-- This is deliberately controlled only through the agent process environment.
-- It gives the integration suite a deterministic way to terminate the agent
-- immediately after a lifecycle boundary, without making the production
-- protocol or domain model aware of test controls.
local function crash_at_boundary(service, boundary)
  if not service or service._fault_boundary ~= boundary then return end
  -- os.exit does not return. The second argument is supported by Lua 5.2+
  -- and ignored by Lua 5.1/LuaJIT, leaving the SQLite process in the same
  -- abrupt-exit condition that the crash-recovery tests need.
  os.exit(137, false)
end

local function history_file_size(path)
  local file, message = io.open(path, "ab")
  if not file then return nil, message end
  local size = file:seek("end") or 0
  file:close()
  return size
end

local function replace_history(path, data)
  local temporary_path = path .. ".tmp"
  local file, message = io.open(temporary_path, "wb")
  if not file then return nil, message end
  local ok, write_message = file:write(data)
  if ok then ok, write_message = file:flush() end
  file:close()
  if not ok then
    os.remove(temporary_path)
    return nil, write_message
  end
  if os.rename(temporary_path, path) then return true end
  -- Windows does not replace an existing file with os.rename. The temporary
  -- file is complete before this fallback removes the old history.
  os.remove(path)
  if os.rename(temporary_path, path) then return true end
  os.remove(temporary_path)
  return nil, "unable to replace runtime history"
end

local function read_file(path, maximum)
  local file, message = io.open(path, "rb")
  if not file then return nil, message end
  local size = file:seek("end") or 0
  if maximum and size > maximum then
    file:close()
    return nil, "file exceeds the maximum allowed size"
  end
  file:seek("set")
  local data = file:read("*a")
  file:close()
  return data or ""
end

local function read_checkpoint(path)
  local data = read_file(path, MAX_CHECKPOINT_BYTES)
  if not data then return nil end
  local ok, checkpoint = pcall(MessagePack.decode, data)
  if not ok or type(checkpoint) ~= "table"
      or checkpoint.version ~= 1
      or type(checkpoint.offset) ~= "number"
      or checkpoint.offset < 0
      or checkpoint.offset ~= math.floor(checkpoint.offset)
      or type(checkpoint.data) ~= "string" then
    return nil
  end
  return checkpoint.offset, checkpoint.data
end

local function write_checkpoint(state, force)
  if not state.emulator or not state.checkpoint_path then return true, false end
  local interval = state.checkpoint_interval_bytes or DEFAULT_CHECKPOINT_INTERVAL_BYTES
  if not force and state.newest_offset - (state.checkpoint_offset or 0) < interval then
    return true, false
  end
  local ok, data = pcall(function() return state.emulator:checkpoint() end)
  if not ok then return nil, tostring(data) end
  if type(data) ~= "string" or #data > MAX_CHECKPOINT_BYTES then
    return nil, "terminal checkpoint exceeds the maximum allowed size"
  end
  local encoded_ok, encoded = pcall(MessagePack.encode, {
    version = 1,
    offset = state.newest_offset,
    data = data,
  })
  if not encoded_ok then return nil, tostring(encoded) end
  local replaced, replace_message = replace_history(state.checkpoint_path, encoded)
  if not replaced then return nil, replace_message end
  state.checkpoint_offset = state.newest_offset
  state.checkpoint_bytes = #data
  return true, true
end

local function read_history_slice(path, relative_offset, length)
  local file, message = io.open(path, "rb")
  if not file then return nil, message end
  file:seek("set", relative_offset)
  local data = file:read(length) or ""
  file:close()
  return data
end

local function history_bounds(path, persisted)
  local size, message = history_file_size(path)
  if not size then return nil, nil, message end
  local newest = persisted.newest_offset
    or persisted.output_offset
    or size
  local oldest = persisted.oldest_offset
  if oldest == nil then oldest = math.max(0, newest - size) end
  if oldest < 0 or newest < oldest or newest - oldest ~= size then
    -- A crash may leave the file and SQLite row at different points. Keep
    -- the newest persisted logical offset and describe the bytes we do have.
    newest = math.max(newest, size)
    oldest = math.max(0, newest - size)
  end
  return oldest, newest
end

local function append_history(path, state, data)
  local oldest = state.oldest_offset or 0
  local newest = state.newest_offset or state.offset or oldest
  local max_bytes = state.max_history_bytes or DEFAULT_MAX_HISTORY_BYTES
  local size, message = history_file_size(path)
  if not size then return nil, message end
  if newest - oldest ~= size then
    oldest = math.max(0, newest - size)
  end

  local new_newest = newest + #data
  local keep_old = math.max(0, max_bytes - #data)
  local old_data = ""
  if keep_old > 0 and size > 0 then
    old_data, message = read_history_slice(path, math.max(0, size - keep_old), keep_old)
    if not old_data then return nil, message end
  end
  local retained = old_data .. data
  if #retained > max_bytes then retained = retained:sub(#retained - max_bytes + 1) end
  local new_oldest = new_newest - #retained
  if #retained ~= size + #data then
    local replaced, replace_message = replace_history(path, retained)
    if not replaced then return nil, replace_message end
  else
    local file, open_message = io.open(path, "ab")
    if not file then return nil, open_message end
    local ok, write_message = file:write(data)
    file:close()
    if not ok then return nil, write_message end
  end
  state.oldest_offset = new_oldest
  state.newest_offset = new_newest
  state.offset = new_newest
  state.output_bytes = new_newest
  return true
end

local function trim_history(path, oldest, newest, max_bytes)
  local size = newest - oldest
  if size <= max_bytes then return oldest, newest end
  local data, message = read_history_slice(path, size - max_bytes, max_bytes)
  if not data then return nil, message end
  local replaced, replace_message = replace_history(path, data)
  if not replaced then return nil, replace_message end
  return newest - max_bytes, newest
end

local function replay_history(path, offset, oldest, newest)
  if offset < oldest then
    return nil, {
      code = "runtime_history_gap", oldest_offset = oldest,
      newest_offset = newest,
    }
  end
  if offset > newest then
    return nil, {
      code = "runtime_replay_error",
      message = "runtime replay offset is beyond the newest available history",
    }
  end
  local length = math.min(64 * 1024, newest - offset)
  local data, message = read_history_slice(path, offset - oldest, length)
  if not data then return nil, { code = "runtime_replay_error", message = message } end
  return data
end

local function runtime_state(runtimes, runtime_id)
  return runtimes[runtime_id]
end

local function remove_runtime_file(history_directory, runtime_id, path)
  if type(path) ~= "string" then return end
  local name = path:match("[^/\\]+$")
  local expected = safe_id(runtime_id)
  if name ~= expected .. ".log" and name ~= expected .. ".log.checkpoint"
      and name ~= expected .. ".checkpoint" then
    return
  end
  local prefix = history_directory .. "/"
  if path:sub(1, #prefix) ~= prefix then return end
  os.remove(path)
  os.remove(path .. ".tmp")
end

local function garbage_collect_runtime_files(service, history_directory)
  if not system.list_dir then return end
  local referenced = {}
  for _, runtime in pairs(service.runtimes) do
    for _, path in ipairs { runtime.history_path, runtime.checkpoint_path } do
      if type(path) == "string" then
        local name = path:match("[^/\\]+$")
        if name then
          referenced[name] = true
          referenced[name .. ".tmp"] = true
        end
      end
    end
  end
  local entries = system.list_dir(history_directory)
  if type(entries) ~= "table" then return end
  for _, name in ipairs(entries) do
    if not referenced[name]
        and (name:match("%.log$") or name:match("%.checkpoint$")
          or name:match("%.tmp$")) then
      os.remove(history_directory .. "/" .. name)
    end
  end
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
    "oldest_offset", "newest_offset", "max_history_bytes", "checkpoint_path",
    "checkpoint_offset", "pid", "metadata", "provider", "external_session_id",
    "capabilities", "execution_policy"
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

local function persist_runtime_history(service, runtime_id, state)
  local result = runtime_transition(service, {}, runtime_id, state.status, {
    resource_id = state.resource_id,
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
    oldest_offset = state.oldest_offset,
    newest_offset = state.newest_offset,
    max_history_bytes = state.max_history_bytes,
    checkpoint_path = state.checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
  }, transition_operation_id(runtime_id, "checkpoint", service.revision),
    service.revision)
  return result.code == "ok", result.message
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

local function provider_action(service, command, resource_id, action)
  local resource = service.resources[resource_id]
  if not resource then
    return nil, service_error(service, command, "not_found",
      "resource not found: " .. tostring(resource_id))
  end
  local allowed, message = service.providers:allows(resource, action)
  if not allowed then
    return nil, service_error(service, command, message.code, message.message)
  end
  return resource
end

local function provider_context(service, command, runtime_id)
  return {
    workspace_id = service.workspace_id,
    runtime_id = runtime_id,
    operation_id = command and command.operation_id,
    command = command,
    resource = command and service.resources[command.resource_id or command.runtime_id
      or command.terminal_id],
    runtime_native = runtime_native,
  }
end

local function provider_error_message(result, fallback)
  if type(result) == "table" then
    return result.code or "provider_error", result.message or fallback
  end
  return "provider_error", tostring(result or fallback)
end

local function runtime_options(service, resource, command)
  local options, message = service.providers:runtime_spec(resource, command, {
    workspace_id = service.workspace_id,
  })
  if not options then return nil, message end
  local metadata, metadata_message = service.providers:runtime_metadata(resource, options, {
    workspace_id = service.workspace_id,
  })
  if not metadata then return nil, metadata_message end
  local provider, provider_message = service.providers:for_resource(resource)
  if not provider then return nil, provider_message end
  return options, metadata, provider
end

local function start_runtime(service, runtimes, history_directory, command, skip_preflight)
  local resource_id = command.resource_id or command.terminal_id or command.runtime_id
  local runtime_id = command.runtime_id or resource_id
  local operation_id = ensure_operation_id(command, runtime_id, "start")
  local previous = not skip_preflight and preflight(service, command)
  if previous then return previous end

  local resource, resource_error = provider_action(service, command, resource_id, "runtime.start")
  if not resource then return resource_error end
  local current = runtime_state(runtimes, runtime_id)
  if current and current.runtime then
    return {
      code = "ok", operation_id = operation_id,
      revision = service.revision, runtime_id = runtime_id,
    }
  end

  local persisted = service.runtimes[runtime_id] or {}
  if command.external_session_id == nil and persisted.external_session_id then
    -- A restarted agent can reattach an OpenCode session from the durable
    -- provider metadata instead of creating a second remote session.
    command.external_session_id = persisted.external_session_id
  end
  local history_path = persisted.history_path
    or (history_directory .. "/" .. safe_id(runtime_id) .. ".log")
  local checkpoint_path = persisted.checkpoint_path or (history_path .. ".checkpoint")
  local configured = resource.config or {}
  local max_history_bytes = command.max_history_bytes
    or configured.max_history_bytes
    or persisted.max_history_bytes
    or DEFAULT_MAX_HISTORY_BYTES
  if type(max_history_bytes) ~= "number" or max_history_bytes < 1
      or max_history_bytes ~= math.floor(max_history_bytes) then
    return service_error(service, command, "invalid_command",
      "runtime.max_history_bytes must be a positive integer")
  end
  local oldest_offset, newest_offset, history_message = history_bounds(history_path, persisted)
  if not oldest_offset then
    return service_error(service, command, "storage_error", history_message)
  end
  local trimmed_oldest, trim_message = trim_history(history_path, oldest_offset,
    newest_offset, max_history_bytes)
  if not trimmed_oldest then
    return service_error(service, command, "storage_error", trim_message)
  end
  oldest_offset = trimmed_oldest

  local options, provider_metadata, provider = runtime_options(service, resource, command)
  if not options then
    return service_error(service, command, provider_metadata.code, provider_metadata.message)
  end
  local context = provider_context(service, command, runtime_id)
  local available, availability_message = service.providers:available(resource, context)
  if not available then
    local code, message = provider_error_message(availability_message,
      "runtime provider is unavailable")
    return service_error(service, command, code, message)
  end
  local checkpoint_interval_bytes = command.checkpoint_interval_bytes
    or configured.checkpoint_interval_bytes or DEFAULT_CHECKPOINT_INTERVAL_BYTES
  if type(checkpoint_interval_bytes) ~= "number"
      or checkpoint_interval_bytes < 1
      or checkpoint_interval_bytes ~= math.floor(checkpoint_interval_bytes) then
    return service_error(service, command, "invalid_command",
      "runtime.checkpoint_interval_bytes must be a positive integer")
  end
  local state = current or {
    id = runtime_id,
    resource_id = resource_id,
    pending = {},
  }
  state.resource_id = resource_id
  state.history_path = history_path
  state.checkpoint_path = checkpoint_path
  state.oldest_offset = oldest_offset
  state.newest_offset = newest_offset
  state.max_history_bytes = max_history_bytes
  state.checkpoint_interval_bytes = checkpoint_interval_bytes
  state.offset = newest_offset
  state.output_bytes = newest_offset
  state.checkpoint_offset = persisted.checkpoint_offset or 0
  state.checkpoint_bytes = 0
  state.provider = resource.provider
  state.external_session_id = command.external_session_id or persisted.external_session_id
  state.metadata = persisted.metadata or provider_metadata
  local capabilities, capability_message = service.providers:capabilities(resource, context)
  if not capabilities then
    local code, message = provider_error_message(capability_message,
      "runtime provider capabilities are unavailable")
    return service_error(service, command, code, message)
  end
  state.capabilities = capabilities
  state.execution_policy = options.execution_policy
    or command.execution_policy or configured.execution_policy or {}
  -- Some consumers only need durable runtime output and replay. Let them
  -- opt out of screen rendering so history throughput is independent of the
  -- terminal emulator's parsing cost.
  local emulator_enabled = configured.emulator ~= false
  local emulator_error = emulator_enabled and terminal_emulator_load_error or nil
  if emulator_enabled and terminal_emulator then
    local emulator_ok, emulator = pcall(terminal_emulator.new, {
      columns = options.columns,
      rows = options.rows,
      scrollback_limit = options.scrollback_limit,
      term = options.term,
    })
    if not emulator_ok then
      emulator_error = tostring(emulator)
    elseif not emulator then
      emulator_error = "terminal emulator constructor returned no emulator"
    end
    if emulator_ok and emulator then
      local checkpoint_offset, checkpoint_data = read_checkpoint(checkpoint_path)
      if checkpoint_offset and checkpoint_offset >= oldest_offset
          and checkpoint_offset <= newest_offset then
        local restored, restore_result = pcall(function()
          return emulator:restore_checkpoint(checkpoint_data)
        end)
        if restored and restore_result ~= false then
          state.checkpoint_offset = checkpoint_offset
          state.checkpoint_bytes = #checkpoint_data
          state.emulator = emulator
        else
          emulator_error = not restored and tostring(restore_result)
            or "terminal emulator rejected persisted checkpoint"
          pcall(function() emulator:close() end)
        end
      else
        state.emulator = emulator
      end
    end
  end
  state.emulator_error = emulator_error
  state.status = "starting"
  runtimes[runtime_id] = state

  local starting = runtime_transition(service, command, runtime_id, "starting", {
    resource_id = resource_id,
    output_bytes = newest_offset,
    output_offset = newest_offset,
    history_path = history_path,
    oldest_offset = oldest_offset,
    newest_offset = newest_offset,
    max_history_bytes = max_history_bytes,
    checkpoint_path = checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
    metadata = provider_metadata,
    provider = state.provider,
    external_session_id = state.external_session_id,
    capabilities = state.capabilities,
    execution_policy = state.execution_policy,
  }, transition_operation_id(runtime_id, "starting", service.revision),
    command.expected_revision)
  if starting.code ~= "ok" then
    runtimes[runtime_id] = current
    return starting
  end
  crash_at_boundary(service, "after_starting_commit")

  local native_or_message, provider_message = service.providers:start(resource, options, context)
  if not native_or_message then
    local failure_code, message = provider_error_message(provider_message,
      "failed to create runtime")
    local failed = runtime_transition(service, command, runtime_id, "failed", {
      resource_id = resource_id, ended_at = timestamp(), output_bytes = newest_offset,
      output_offset = newest_offset, history_path = history_path,
      oldest_offset = oldest_offset, newest_offset = newest_offset,
      max_history_bytes = max_history_bytes,
      checkpoint_path = checkpoint_path, checkpoint_offset = state.checkpoint_offset,
      metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
    }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
    state.status = failed.code == "ok" and "failed" or "starting"
    return service_error(service, command, failure_code, message)
  end

  state.runtime = native_or_message
  crash_at_boundary(service, "after_process_creation")
  state.started_at = timestamp()
  crash_at_boundary(service, "before_running_commit")
  local result = runtime_transition(service, command, runtime_id, "running", {
    resource_id = resource_id,
    started_at = state.started_at,
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = history_path,
    oldest_offset = state.oldest_offset,
    newest_offset = state.newest_offset,
    max_history_bytes = max_history_bytes,
    checkpoint_path = checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
    metadata = provider_metadata,
  }, operation_id, service.revision)
  if result.code == "ok" then crash_at_boundary(service, "after_running_commit") end
  if result.code ~= "ok" then
    service.providers:stop(resource, state.runtime, context)
    state.runtime = nil
    local failed = runtime_transition(service, command, runtime_id, "failed", {
      resource_id = resource_id, ended_at = timestamp(), output_bytes = newest_offset,
      output_offset = newest_offset, history_path = history_path,
      oldest_offset = oldest_offset, newest_offset = newest_offset,
      max_history_bytes = max_history_bytes,
      checkpoint_path = checkpoint_path, checkpoint_offset = state.checkpoint_offset,
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
      oldest_offset = persisted.oldest_offset or 0,
      newest_offset = persisted.newest_offset or persisted.output_offset or 0,
      max_history_bytes = persisted.max_history_bytes or DEFAULT_MAX_HISTORY_BYTES,
      checkpoint_path = persisted.checkpoint_path
        or (persisted.history_path and persisted.history_path .. ".checkpoint"),
      checkpoint_offset = persisted.checkpoint_offset or 0,
      offset = persisted.newest_offset or persisted.output_offset or 0,
      output_bytes = persisted.output_bytes or persisted.newest_offset
        or persisted.output_offset or 0,
      status = persisted.status,
      provider = persisted.provider,
      external_session_id = persisted.external_session_id,
      metadata = persisted.metadata,
      capabilities = persisted.capabilities,
      execution_policy = persisted.execution_policy,
    }
    runtimes[runtime_id] = state
  end

  local resource, resource_error = provider_action(service, command, state.resource_id,
    "runtime.stop")
  if not resource then return resource_error end

  local stopping = runtime_transition(service, command, runtime_id, "stopping", {
    resource_id = state.resource_id,
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
    oldest_offset = state.oldest_offset,
    newest_offset = state.newest_offset,
    max_history_bytes = state.max_history_bytes,
    checkpoint_path = state.checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
  }, transition_operation_id(runtime_id, "stopping", service.revision),
    skip_preflight and service.revision or command.expected_revision)
  if stopping.code ~= "ok" then return stopping end
  state.status = "stopping"
  crash_at_boundary(service, "after_stopping_commit")

  if state.runtime then
    crash_at_boundary(service, "during_close")
    local closed, close_message = service.providers:stop(resource, state.runtime,
      provider_context(service, command, runtime_id))
    if not closed then
      state.status = "failed"
      local message = close_message and (close_message.message or tostring(close_message))
        or "runtime close failed"
      runtime_transition(service, command, runtime_id, "failed", {
        resource_id = state.resource_id, ended_at = timestamp(),
        output_bytes = state.output_bytes, output_offset = state.offset,
        history_path = state.history_path,
        oldest_offset = state.oldest_offset,
        newest_offset = state.newest_offset,
        max_history_bytes = state.max_history_bytes,
        checkpoint_path = state.checkpoint_path,
        checkpoint_offset = state.checkpoint_offset,
        metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
      }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
      return service_error(service, command, "runtime_error", message)
    end
    state.runtime = nil
  end

  -- Checkpoint after the final output has been appended, before persisting the
  -- stopped transition. A failed checkpoint is recoverable from history.
  write_checkpoint(state, true)
  crash_at_boundary(service, "before_stopped_commit")

  local result = runtime_transition(service, command, runtime_id, "stopped", {
    resource_id = state.resource_id,
    ended_at = timestamp(),
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
    oldest_offset = state.oldest_offset,
    newest_offset = state.newest_offset,
    max_history_bytes = state.max_history_bytes,
    checkpoint_path = state.checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
  }, operation_id, service.revision)
  if result.code == "ok" then crash_at_boundary(service, "after_stopped_commit") end
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

local function resize_runtime(service, runtimes, command)
  local state = runtime_state(runtimes, command.runtime_id)
  if not state or not state.runtime then
    return { code = "runtime_not_running", message = "runtime is not running" }
  end
  local resource, resource_error = provider_action(service, command, state.resource_id,
    "runtime.resize")
  if not resource then return resource_error end
  local ok, message = service.providers:action(resource, state.runtime, "resize", {
    columns = command.columns or command.cols,
    rows = command.rows,
  }, provider_context(service, command, command.runtime_id))
  if not ok then
    local code, detail = provider_error_message(message, "runtime resize failed")
    return { code = code, message = detail }
  end
  return { code = "ok", runtime_id = command.runtime_id }
end

local function input_runtime(service, runtimes, command)
  local state = runtime_state(runtimes, command.runtime_id)
  if not state or not state.runtime then
    return { code = "runtime_not_running", message = "runtime is not running" }
  end
  local resource, resource_error = provider_action(service, command, state.resource_id,
    "runtime.input")
  if not resource then return resource_error end
  local written, write_message = service.providers:send_input(resource, state.runtime,
    command.data or "", provider_context(service, command, command.runtime_id))
  if written == nil then
    local code, detail = provider_error_message(write_message, "runtime input failed")
    return { code = code, message = detail }
  end
  return { code = "ok", runtime_id = command.runtime_id, written = written }
end

local function replay_runtime(service, runtimes, command)
  local state = runtime_state(runtimes, command.runtime_id)
  local persisted = service.runtimes[command.runtime_id]
  local resource_id = state and state.resource_id or persisted and persisted.resource_id
  local resource, resource_error = provider_action(service, command, resource_id,
    "runtime.replay")
  if not resource then return resource_error end
  local path = state and state.history_path or persisted and persisted.history_path
  if not path then
    return { code = "runtime_not_found", message = "runtime history is not available" }
  end
  local offset = command.offset or 0
  local oldest_offset = state and state.oldest_offset
    or persisted and persisted.oldest_offset or 0
  local newest_offset = state and state.newest_offset
    or persisted and (persisted.newest_offset or persisted.output_offset) or 0
  local max_history_bytes = state and state.max_history_bytes
    or persisted and persisted.max_history_bytes or DEFAULT_MAX_HISTORY_BYTES
  -- A checkpoint can accelerate replay only after confirming that the
  -- requested byte offset is still available. Otherwise a request for bytes
  -- lost to history rotation would incorrectly look like a successful replay
  -- from the checkpoint.
  if offset < oldest_offset then
    return {
      code = "runtime_history_gap", oldest_offset = oldest_offset,
      newest_offset = newest_offset,
    }
  end
  local replay_offset = offset
  local events = {}
  -- A running runtime has a more authoritative screen than its persisted
  -- history. Send that live emulator state on every attachment so a missing
  -- or empty history file cannot produce a blank terminal.
  local live_checkpoint
  if state and state.emulator then
    local captured, checkpoint_data = pcall(function()
      return state.emulator:checkpoint()
    end)
    if captured and type(checkpoint_data) == "string" then
      live_checkpoint = {
        type = "checkpoint", runtime_id = command.runtime_id,
        offset = newest_offset, data = checkpoint_data,
        oldest_offset = oldest_offset, newest_offset = newest_offset,
        live = true,
      }
    end
  end
  local checkpoint_path = state and state.checkpoint_path
    or persisted and persisted.checkpoint_path
  local checkpoint_offset, checkpoint_data
  if not live_checkpoint and checkpoint_path then
    checkpoint_offset, checkpoint_data = read_checkpoint(checkpoint_path)
  end
  if not live_checkpoint and checkpoint_offset and checkpoint_data and offset < checkpoint_offset
      and checkpoint_offset >= oldest_offset and checkpoint_offset <= newest_offset then
    events[#events + 1] = {
      type = "checkpoint", runtime_id = command.runtime_id,
      offset = checkpoint_offset, data = checkpoint_data,
      oldest_offset = oldest_offset, newest_offset = newest_offset,
    }
    replay_offset = checkpoint_offset
  end
  local data, replay_error = replay_history(path, replay_offset, oldest_offset, newest_offset)
  if not data and not live_checkpoint then return replay_error end
  if data and #data > 0 then
    events[#events + 1] = {
      type = "output", runtime_id = command.runtime_id,
      offset = replay_offset, data = data,
      oldest_offset = oldest_offset, newest_offset = newest_offset,
    }
  end
  if live_checkpoint then
    events[#events + 1] = live_checkpoint
    checkpoint_offset = newest_offset
  end
  return { code = "ok", runtime_id = command.runtime_id,
    offset = offset, available = newest_offset, oldest_offset = oldest_offset,
    newest_offset = newest_offset, max_history_bytes = max_history_bytes,
    checkpoint_offset = checkpoint_offset,
    runtime_events = events }
end

local function delete_runtime_history(service, runtimes, history_directory, command)
  local runtime_id = command.runtime_id
  local state = runtime_state(runtimes, runtime_id)
  local persisted = service.runtimes[runtime_id]
  local history_path = state and state.history_path or persisted and persisted.history_path
  local checkpoint_path = state and state.checkpoint_path
    or persisted and persisted.checkpoint_path
  if state and state.runtime then
    return service_error(service, command, "runtime_active",
      "runtime history cannot be deleted while the runtime is active")
  end
  local result = service:execute(command)
  if result.code == "ok" then
    if state and state.emulator then pcall(function() state.emulator:close() end) end
    runtimes[runtime_id] = nil
    remove_runtime_file(history_directory, runtime_id, history_path)
    remove_runtime_file(history_directory, runtime_id, checkpoint_path)
  end
  return result
end

local function delete_resource(service, runtimes, history_directory, command)
  local resource_id = command.resource_id or command.terminal_id or command.id
  local removed = {}
  for runtime_id, state in pairs(runtimes) do
    if state.resource_id == resource_id then
      if state.runtime then
        return service_error(service, command, "runtime_active",
          "resource cannot be deleted while its runtime is active")
      end
      removed[#removed + 1] = {
        id = runtime_id,
        history_path = state.history_path,
        checkpoint_path = state.checkpoint_path,
        emulator = state.emulator,
      }
    end
  end
  local result = service:execute(command)
  if result.code == "ok" then
    for _, runtime in ipairs(removed) do
      if runtime.emulator then pcall(function() runtime.emulator:close() end) end
      runtimes[runtime.id] = nil
      remove_runtime_file(history_directory, runtime.id, runtime.history_path)
      remove_runtime_file(history_directory, runtime.id, runtime.checkpoint_path)
    end
  end
  return result
end

local function finish_runtime(service, runtimes, runtime_id, state, exit_code, signal)
  if state.runtime then
    local resource = service.resources[state.resource_id]
    service.providers:stop(resource, state.runtime,
      provider_context(service, nil, runtime_id))
    state.runtime = nil
  end
  write_checkpoint(state, true)
  local result = runtime_transition(service, {}, runtime_id, "exited", {
    resource_id = state.resource_id,
    ended_at = timestamp(),
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
    oldest_offset = state.oldest_offset,
    newest_offset = state.newest_offset,
    max_history_bytes = state.max_history_bytes,
    checkpoint_path = state.checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
  }, transition_operation_id(runtime_id, "exited", service.revision), service.revision)
  if result.code == "ok" then
    state.status = "exited"
    queue_runtime_event(state, {
      type = "status", runtime_id = runtime_id, status = "exited",
      exit_code = exit_code, signal = signal, offset = state.offset,
      oldest_offset = state.oldest_offset, newest_offset = state.newest_offset,
    })
  else
    state.status = "interrupted"
  end
end

local function fail_runtime(service, runtime_id, state, message)
  if state.runtime then
    local resource = service.resources[state.resource_id]
    service.providers:stop(resource, state.runtime,
      provider_context(service, nil, runtime_id))
    state.runtime = nil
  end
  write_checkpoint(state, true)
  local failed = runtime_transition(service, {}, runtime_id, "failed", {
    resource_id = state.resource_id,
    ended_at = timestamp(),
    output_bytes = state.output_bytes,
    output_offset = state.offset,
    history_path = state.history_path,
    oldest_offset = state.oldest_offset,
    newest_offset = state.newest_offset,
    max_history_bytes = state.max_history_bytes,
    checkpoint_path = state.checkpoint_path,
    checkpoint_offset = state.checkpoint_offset,
    metadata = runtime_failure_metadata(service.runtimes[runtime_id], message),
  }, transition_operation_id(runtime_id, "failed", service.revision), service.revision)
  if failed.code == "ok" then
    state.status = "failed"
    queue_runtime_event(state, {
      type = "status", runtime_id = runtime_id, status = "failed",
      message = message, offset = state.offset,
      oldest_offset = state.oldest_offset, newest_offset = state.newest_offset,
    })
  else
    state.status = "interrupted"
  end
  return failed
end

local function poll_runtimes(service, runtimes)
  for runtime_id, state in pairs(runtimes) do
    if state.runtime then
      local resource = service.resources[state.resource_id]
      local status, status_message = service.providers:refresh_status(resource, state.runtime,
        provider_context(service, nil, runtime_id))
      if not status then
        local _, message = provider_error_message(status_message, "runtime status refresh failed")
        fail_runtime(service, runtime_id, state, message)
      else
        local provider_changed = status.external_session_id ~= nil
          and status.external_session_id ~= state.external_session_id
        if provider_changed then
          state.external_session_id = status.external_session_id
          state.metadata = status.metadata or state.metadata
          local persisted_result = runtime_transition(service, {}, runtime_id, state.status, {
            resource_id = state.resource_id,
            external_session_id = state.external_session_id,
            metadata = state.metadata,
            provider = state.provider,
            capabilities = state.capabilities,
            execution_policy = state.execution_policy,
            output_bytes = state.output_bytes,
            output_offset = state.offset,
            history_path = state.history_path,
            oldest_offset = state.oldest_offset,
            newest_offset = state.newest_offset,
            max_history_bytes = state.max_history_bytes,
            checkpoint_path = state.checkpoint_path,
            checkpoint_offset = state.checkpoint_offset,
          }, transition_operation_id(runtime_id, "provider", service.revision),
            service.revision)
          if persisted_result.code ~= "ok" then
            fail_runtime(service, runtime_id, state, persisted_result.message)
          end
        end
        local data = status.output
        if type(data) == "string" and #data > 0 then
          local written, message = append_history(state.history_path, state, data)
          if written then
            local checkpointed, checkpoint_message = true
            if state.emulator then
              local fed, feed_message = pcall(function() return state.emulator:feed(data) end)
              if not fed then checkpointed, checkpoint_message = false, tostring(feed_message) end
              if fed then
                local replied, reply_or_message = pcall(function()
                  return state.emulator:take_input()
                end)
                if not replied then
                  checkpointed, checkpoint_message = false, tostring(reply_or_message)
                elseif #reply_or_message > 0 then
                  local sent, send_message = service.providers:send_input(
                    resource, state.runtime, reply_or_message,
                    provider_context(service, nil, runtime_id))
                  if not sent then
                    local _, detail = provider_error_message(send_message,
                      "terminal reply write failed")
                    checkpointed, checkpoint_message = false, detail
                  end
                end
              end
            elseif state.emulator_error then
              checkpointed, checkpoint_message = false, state.emulator_error
            end
            if checkpointed then
              local checkpoint_changed, checkpoint_result
              checkpoint_changed, checkpoint_result = write_checkpoint(state, false)
              if not checkpoint_changed then
                checkpointed, checkpoint_message = false, checkpoint_result
              elseif checkpoint_result then
                checkpointed, checkpoint_message = persist_runtime_history(
                  service, runtime_id, state)
              end
            end
            local offset = state.newest_offset - #data
            queue_runtime_event(state, {
              type = "output", runtime_id = runtime_id,
              offset = offset, data = data,
              oldest_offset = state.oldest_offset,
              newest_offset = state.newest_offset,
            })
            if not checkpointed then
              queue_runtime_event(state, {
                type = "status", runtime_id = runtime_id, status = "error",
                message = checkpoint_message, offset = state.newest_offset,
              })
            end
          else
            queue_runtime_event(state, {
              type = "status", runtime_id = runtime_id, status = "error",
              message = message, offset = state.newest_offset,
            })
          end
        end
        if status.status == "exited" then
          finish_runtime(service, runtimes, runtime_id, state,
            status.exit_code, status.signal)
        end
      end
    end
  end
end

local function poll_degraded_runtimes(service, runtimes, storage_error)
  for runtime_id, state in pairs(runtimes) do
    if state.runtime then
      local resource = service.resources[state.resource_id]
      local status = service.providers:refresh_status(resource, state.runtime,
        provider_context(service, nil, runtime_id))
      if status then
        local data = status.output
        if type(data) == "string" and #data > 0 then
          if state.emulator then
            pcall(function()
              state.emulator:feed(data)
              local reply = state.emulator:take_input()
              if #reply > 0 then
                service.providers:send_input(resource, state.runtime, reply,
                  provider_context(service, nil, runtime_id))
              end
            end)
          end
          local offset = state.newest_offset
          state.newest_offset = offset + #data
          state.offset = state.newest_offset
          state.output_bytes = (state.output_bytes or offset) + #data
          queue_runtime_event(state, {
            type = "output", runtime_id = runtime_id, offset = offset, data = data,
            oldest_offset = state.oldest_offset,
            newest_offset = state.newest_offset, volatile = true,
          })
        end
        if status.status == "exited" then
          state.runtime = nil
          state.status = "interrupted"
          queue_runtime_event(state, {
            type = "status", runtime_id = runtime_id, status = "error",
            message = storage_error, offset = state.newest_offset,
          })
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
    local compatibility, compatibility_message = Protocol.compatibility(message)
    if not compatibility then
      return enqueue(client, error_message(message.request_id, "protocol_incompatible",
        compatibility_message))
    end
    if message.workspace_id and message.workspace_id ~= workspace_id then
      return enqueue(client, error_message(message.request_id, "workspace_mismatch",
        "requested workspace does not match the agent workspace"))
    end
    if message.storage_path and message.storage_path ~= options.storage_path then
      return enqueue(client, error_message(message.request_id, "storage_mismatch",
        "requested storage does not match the agent storage"))
    end
    return enqueue(client, Protocol.request("hello_result", message.request_id, {
      ok = true,
      workspace_id = workspace_id,
      protocol_major = compatibility.major,
      protocol_minor = compatibility.minor,
      revision = service.revision,
      capabilities = {
        event_replay = true,
        event_cursors = true,
        sqlite = true,
        runtimes = true,
        runtime_replay = true,
        providers = true,
      },
      capability_versions = {
        event_replay = 1,
        event_cursors = 1,
        sqlite = 1,
        runtimes = 1,
        runtime_replay = 1,
        providers = 1,
      },
      providers = service.providers:describe(),
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
    if options.storage_error then
      return enqueue(client, Protocol.request("result", message.request_id, {
        result = { code = "storage_unavailable", message = options.storage_error },
      }))
    end
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
    local valid, validation_message = validation.command(command)
    if not valid then
      return enqueue(client, error_message(message.request_id, "invalid_command",
        validation_message))
    end
    if options.storage_error and command.type ~= "runtime.replay" then
      return enqueue(client, Protocol.request("result", message.request_id, {
        result = { code = "storage_unavailable", message = options.storage_error },
      }))
    end
    local result
    if command.type == "runtime.start" then
      result = start_runtime(service, runtimes, history_directory, command)
    elseif command.type == "runtime.restart" then
      result = restart_runtime(service, runtimes, history_directory, command)
    elseif command.type == "runtime.stop" then
      result = stop_runtime(service, runtimes, command)
    elseif command.type == "runtime.input" then
      result = input_runtime(service, runtimes, command)
    elseif command.type == "runtime.resize" then
      result = resize_runtime(service, runtimes, command)
    elseif command.type == "runtime.replay" then
      result = replay_runtime(service, runtimes, command)
    elseif command.type == "runtime.delete_history" then
      result = delete_runtime_history(service, runtimes, history_directory, command)
    elseif command.type == "resource.delete" or command.type == "terminal.delete" then
      result = delete_resource(service, runtimes, history_directory, command)
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
      oldest_offset = persisted.oldest_offset or 0,
      newest_offset = persisted.newest_offset or persisted.output_offset or 0,
      max_history_bytes = persisted.max_history_bytes or DEFAULT_MAX_HISTORY_BYTES,
      checkpoint_path = persisted.checkpoint_path
        or (persisted.history_path and persisted.history_path .. ".checkpoint"),
      checkpoint_offset = persisted.checkpoint_offset or 0,
      offset = persisted.newest_offset or persisted.output_offset or 0,
      output_bytes = persisted.output_bytes or persisted.newest_offset
        or persisted.output_offset or 0,
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
        oldest_offset = state.oldest_offset,
        newest_offset = state.newest_offset,
        max_history_bytes = state.max_history_bytes,
        checkpoint_path = state.checkpoint_path,
        checkpoint_offset = state.checkpoint_offset,
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
  if options.fault_boundary == nil and os and os.getenv then
    options.fault_boundary = os.getenv("WORKBENCH_AGENT_FAULT_BOUNDARY")
  end
  assert(type(options.endpoint) == "string", "Workbench agent endpoint is required")
  assert(type(options.storage_path) == "string", "Workbench agent storage path is required")
  local directory = options.endpoint:match("^(.+)[/\\][^/\\]+$")
  if directory then common.mkdirp(directory) end

  local store, message = Storage.new(options.storage_path, {
    event_limit = options.event_limit,
  })
  assert(store, message)
  local storage_identity = system.get_file_info(options.storage_path)
  local service = Service.new {
    workspace_id = options.workspace_id or "default",
    store = store,
    event_limit = options.event_limit,
  }
  service._fault_boundary = options.fault_boundary
  local history_directory = (options.data_dir or directory or ".") .. "/workbench-runtimes"
  local history_ok, history_message = common.mkdirp(history_directory)
  assert(history_ok, history_message)
  garbage_collect_runtime_files(service, history_directory)
  local runtimes = {}
  reconcile_runtimes(service, runtimes)
  local server, listen_message = transport.listen(options.endpoint)
  assert(server, listen_message)

  local served = false
  local clients = {}

  local function check_storage()
    if options.storage_error then return false end
    local current = system.get_file_info(options.storage_path)
    local same = current and storage_identity
      and (not storage_identity.device or current.device == storage_identity.device)
      and (not storage_identity.inode or current.inode == storage_identity.inode)
      and (not current.links or current.links > 0)
    if same then return true end
    options.storage_error = "Workbench storage was removed or replaced; "
      .. "live runtimes are preserved in volatile mode"
    for runtime_id, state in pairs(runtimes) do
      queue_runtime_event(state, {
        type = "status", runtime_id = runtime_id, status = "error",
        message = options.storage_error, offset = state.newest_offset,
      })
    end
    return false
  end

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

    if check_storage() then
      poll_runtimes(service, runtimes)
    else
      poll_degraded_runtimes(service, runtimes, options.storage_error)
    end
    service.providers:poll {
      workspace_id = service.workspace_id,
      runtimes = runtimes,
    }
    local runtime_events = queue_runtime_events(runtimes)
    for index = #clients, 1, -1 do
      local ok = flush_client(clients[index], runtime_events)
      if not ok then remove_client(index) end
    end

    if options.once and served and #clients == 0 then break end
  end

  local providers_shutdown, shutdown_message = service.providers:shutdown {
    workspace_id = service.workspace_id,
    runtimes = runtimes,
  }
  server:close()
  service:close()
  if not providers_shutdown then
    error(shutdown_message and (shutdown_message.message or tostring(shutdown_message))
      or "Workbench provider shutdown failed")
  end
  return served or not options.once
end

return Agent
