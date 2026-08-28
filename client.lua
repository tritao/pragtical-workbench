local native_available, native = pcall(require, "workbench")
local transport_available, transport = pcall(require, "local_transport")
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"
local Protocol = require "plugins.workbench.service.protocol"

local next_operation = 0
local services = {}
local agent_processes = {}

local Client = {}
Client.__index = Client

local DEFAULT_REQUEST_TIMEOUT = 10
local MAX_OUTBOUND_MESSAGES = 1024
local MAX_OUTBOUND_BYTES = 8 * 1024 * 1024
local PENDING = {}

local Request = {}
Request.__index = Request

function Request:cancel()
  return self.client:cancel(self)
end

function Request:is_done()
  return self.done
end

function Request:result()
  return self.value, self.error
end

local function next_id(prefix)
  next_operation = next_operation + 1
  return prefix .. "-" .. tostring(next_operation)
end

local function safe_path_component(value)
  local component = tostring(value or "default"):gsub("[^%w_.-]", "_")
  return component ~= "" and component or "default"
end

local function path_identity(value)
  local normalized = tostring(value or "default")
  if system and system.absolute_path then
    local ok, absolute = pcall(system.absolute_path, normalized)
    if ok and absolute then normalized = absolute end
  end
  normalized = normalized:gsub("\\", "/")
  if PLATFORM == "Windows" then normalized = normalized:lower() end
  local first, second = 5381, 52711
  for index = 1, #normalized do
    local byte = normalized:byte(index)
    first = (first * 33 + byte) % 4294967296
    second = (second * 65599 + byte) % 4294967296
  end
  return string.format("%08x%08x", first, second)
end

local function path_directory(path, fallback)
  return path and path:match("^(.+)[/\\][^/\\]+$") or fallback
end

local function default_storage_path(workspace_id)
  if type(USERDIR) ~= "string" then return nil end
  return USERDIR .. PATHSEP .. "workbench" .. PATHSEP
    .. safe_path_component(workspace_id) .. PATHSEP .. "workbench.sqlite3"
end

local function default_agent_endpoint(user_dir, workspace_id)
  if PLATFORM ~= "Windows" and type(os) == "table" and type(os.getenv) == "function" then
    local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
    if type(runtime_dir) == "string" and runtime_dir ~= "" then
      return runtime_dir .. PATHSEP .. "pragtical" .. PATHSEP .. "workbench"
        .. PATHSEP .. path_identity(user_dir) .. PATHSEP
        .. safe_path_component(workspace_id) .. ".sock"
    end
  end
  return user_dir .. PATHSEP .. "workbench.sock"
end

local function file_exists(path)
  local info = path and system.get_file_info(path)
  return info and info.type == "file"
end

local function agent_executable()
  local suffix = PLATFORM == "Windows" and ".exe" or ""
  local candidates = {}
  if type(PRAGTICAL_PROJECT_BUILD_DIR) == "string"
      and PRAGTICAL_PROJECT_BUILD_DIR ~= "" then
    candidates[#candidates + 1] = PRAGTICAL_PROJECT_BUILD_DIR .. PATHSEP
      .. "src" .. PATHSEP .. "workbench-agent" .. suffix
  end
  if type(EXEDIR) == "string" then
    candidates[#candidates + 1] = EXEDIR .. PATHSEP .. "workbench-agent" .. suffix
  end
  for _, path in ipairs(candidates) do
    if file_exists(path) then return path end
  end
  return nil
end

local function connect_endpoint(endpoint)
  local ok, connection, message = pcall(transport.connect, endpoint)
  if not ok then return nil, connection end
  if connection then return connection end
  return nil, message or "Workbench agent is not listening"
end

local function start_agent(options, endpoint, data_dir, storage_path, workspace_id)
  local current = agent_processes[endpoint]
  if current then
    local ok, running = pcall(function() return current:running() end)
    if ok and running then return true end
    agent_processes[endpoint] = nil
  end

  local executable = options.agent_executable or agent_executable()
  if not executable then
    return nil, "Workbench agent executable was not found"
  end
  local ok, process_handle, message = pcall(process.start, {
    executable,
    "--data-root", DATADIR,
    "--data-dir", data_dir,
    "--endpoint", endpoint,
    "--storage-path", storage_path,
    "--workspace", workspace_id,
  }, {
    detach = true,
    stdin = process.REDIRECT_DISCARD,
    stdout = process.REDIRECT_DISCARD,
    -- Keep startup diagnostics available until the client has connected. An
    -- agent that exits before binding its endpoint must not look like a
    -- terminal that is perpetually loading.
    stderr = process.REDIRECT_PIPE,
  })
  if not ok then return nil, process_handle end
  if not process_handle then
    return nil, message or "Unable to start Workbench agent"
  end
  agent_processes[endpoint] = process_handle
  return true
end

local function connect_or_start_agent(options, endpoint, data_dir, storage_path, workspace_id)
  local connection, message = connect_endpoint(endpoint)
  if connection then return connection end

  local started, start_message = start_agent(options, endpoint, data_dir, storage_path,
    workspace_id)
  if not started then
    return nil, start_message or message
  end

  local deadline = system.get_time() + (options.start_timeout or 2)
  repeat
    system.sleep(0.02)
    connection, message = connect_endpoint(endpoint)
    if connection then return connection end
    local current = agent_processes[endpoint]
    if current then
      local running_ok, running = pcall(function() return current:running() end)
      if running_ok and not running then
        local diagnostics = ""
        if current.stderr then
          local read_ok, output = pcall(function() return current.stderr:read("all") end)
          if read_ok and type(output) == "string" then
            diagnostics = output:gsub("%s+$", "")
          end
        end
        agent_processes[endpoint] = nil
        return nil, diagnostics ~= "" and diagnostics
          or "Workbench agent exited during startup"
      end
    end
  until system.get_time() >= deadline
  return nil, message or "Timed out waiting for Workbench agent"
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

local function projection_upsert(snapshot, field, id, record)
  if not snapshot or not id or type(record) ~= "table" then return false end
  local records = snapshot[field] or {}
  snapshot[field] = records
  for index, current in ipairs(records) do
    if current.id == id or current.provider_id == id then
      records[index] = record
      return true
    end
  end
  records[#records + 1] = record
  return true
end

local function projection_remove(snapshot, field, id)
  if not snapshot or not id then return false end
  local records = snapshot[field] or {}
  for index, current in ipairs(records) do
    if current.id == id or current.provider_id == id then
      table.remove(records, index)
      return true
    end
  end
  return true
end

local function refresh_terminal_projection(snapshot)
  local terminals = {}
  for _, resource in ipairs(snapshot.resources or {}) do
    if resource.kind == "terminal" then terminals[#terminals + 1] = resource end
  end
  snapshot.terminals = terminals
end

local function apply_agent_event(snapshot, event)
  if not snapshot or type(event) ~= "table" then return false end
  -- An idempotent retry can return an event from before the agent restarted
  -- and reconciled the runtime. Never let that older event overwrite the
  -- recovered projection or move its revision backwards.
  if event.revision and snapshot.revision
      and event.revision < snapshot.revision then
    return false
  end
  local event_type = event.type
  local id = event.entity_id
  local record = event.record
  local applied = false

  if event_type == "collection.created" then
    record = record or {
      id = id, parent_id = event.parent_id or "root", title = event.title or "",
    }
    applied = projection_upsert(snapshot, "collections", id, record)
  elseif event_type == "collection.updated" or event_type == "collection.moved"
      or event_type == "collection.archived" then
    applied = projection_upsert(snapshot, "collections", id, record)
  elseif event_type == "collection.deleted" then
    applied = projection_remove(snapshot, "collections", id)
  elseif event_type == "task.created" then
    record = record or { id = id, title = event.title or "" }
    applied = projection_upsert(snapshot, "tasks", id, record)
  elseif event_type == "task.updated" or event_type == "task.moved"
      or event_type == "task.archived" then
    applied = projection_upsert(snapshot, "tasks", id, record)
  elseif event_type == "task.deleted" then
    applied = projection_remove(snapshot, "tasks", id)
  elseif event_type == "resource.created" then
    record = record or {
      id = id, kind = event.kind or "terminal", provider = event.provider,
      title = event.title or "", status = "stopped",
    }
    applied = projection_upsert(snapshot, "resources", id, record)
    refresh_terminal_projection(snapshot)
  elseif event_type == "resource.updated" or event_type == "resource.archived"
      or event_type == "runtime.status_changed" then
    applied = projection_upsert(snapshot, "resources", id, record)
    refresh_terminal_projection(snapshot)
  elseif event_type == "resource.deleted" then
    applied = projection_remove(snapshot, "resources", id)
    refresh_terminal_projection(snapshot)
  elseif event_type == "runtime.updated" then
    applied = projection_upsert(snapshot, "runtimes", id, record)
    if event.resource then
      projection_upsert(snapshot, "resources", event.resource.id, event.resource)
      refresh_terminal_projection(snapshot)
    elseif event.resource_id then
      for _, resource in ipairs(snapshot.resources or {}) do
        if resource.id == event.resource_id then resource.status = event.status end
      end
      refresh_terminal_projection(snapshot)
    end
  elseif event_type == "runtime.deleted" then
    applied = projection_remove(snapshot, "runtimes", id)
  elseif event_type == "provider.metadata_updated" then
    record = record and (function()
      local copy = {}
      for key, value in pairs(record) do copy[key] = value end
      copy.id = copy.id or copy.provider_id
      return copy
    end)()
    applied = projection_upsert(snapshot, "provider_metadata", id, record)
  elseif event_type == "workspace.renamed" then
    snapshot.name = event.name or (record and record.name) or snapshot.name
    applied = true
  end

  if applied then
    if event.revision then
      snapshot.revision = math.max(snapshot.revision or 0, event.revision)
    end
    if event.event_sequence then
      snapshot.event_cursor = math.max(snapshot.event_cursor or 0, event.event_sequence)
    end
  end
  return applied
end

function Client:_new_request(id, callback, options)
  options = options or {}
  local timeout = options.timeout
  if timeout == nil then timeout = self.request_timeout or DEFAULT_REQUEST_TIMEOUT end
  if type(timeout) ~= "number" or timeout < 0 then timeout = DEFAULT_REQUEST_TIMEOUT end
  local request = setmetatable({
    client = self,
    id = id,
    callback = callback,
    done = false,
    value = nil,
    error = nil,
    pending_ids = {},
    deadline = system.get_time() + timeout,
  }, Request)
  self.requests[id] = request
  return request
end

function Client:_finish_request(request, value, error)
  if not request or request.done then return end
  request.done = true
  request.value = value
  request.error = error
  if self.requests[request.id] == request then
    self.requests[request.id] = nil
  end
  if request.callback then
    pcall(request.callback, value, error, request)
  end
end

function Client:_schedule_work(request, work)
  self.completions[#self.completions + 1] = {
    request = request,
    work = work,
  }
end

function Client:_drain_completions()
  local count = 0
  while #self.completions > 0 do
    local completion = table.remove(self.completions, 1)
    if not completion.request.done then
      local ok, value = pcall(completion.work)
      if ok then
        self:_finish_request(completion.request, value, nil)
      else
        self:_finish_request(completion.request, nil, agent_error("client_error", value))
      end
      count = count + 1
    end
  end
  return count
end

function Client:_queue_agent(message, expected_kind, request, handler)
  if not self.connection then
    return nil, agent_error("agent_disconnected", "Workbench agent is disconnected")
  end
  local encoded
  local encoded_ok, encode_message = pcall(Protocol.encode, message)
  if not encoded_ok then
    return nil, agent_error("invalid_protocol", encode_message)
  end
  encoded = encode_message
  if #self.outgoing >= MAX_OUTBOUND_MESSAGES
      or self.outgoing_bytes + #encoded > MAX_OUTBOUND_BYTES then
    return nil, agent_error("agent_backpressure",
      "Workbench client outbound queue limit exceeded")
  end
  self.outgoing[#self.outgoing + 1] = encoded
  self.outgoing_bytes = self.outgoing_bytes + #encoded
  if request then
    self.pending_requests[message.request_id] = {
      request = request,
      expected_kind = expected_kind,
      handler = handler,
      deadline = request.deadline,
    }
    request.pending_ids[message.request_id] = true
  end
  return true
end

function Client:_flush_outgoing()
  if not self.connection then return nil, "Workbench agent is disconnected" end

  if self.write_pending then
    local called, flushed, message = pcall(function()
      return self.connection:flush()
    end)
    if not called then return nil, flushed end
    if not flushed then
      if message == "would_block" then return true end
      return nil, message or "agent send failed"
    end
    self.write_pending = false
  end

  while #self.outgoing > 0 do
    local frame = self.outgoing[1]
    local called, sent, message = pcall(function()
      return self.connection:send(frame)
    end)
    if not called then return nil, sent end
    if sent then
      table.remove(self.outgoing, 1)
      self.outgoing_bytes = self.outgoing_bytes - #frame
    elseif message == "would_block" then
      -- The native transport owns the partially written frame now. Remove it
      -- from the Lua queue and let the next poll turn finish it.
      table.remove(self.outgoing, 1)
      self.outgoing_bytes = self.outgoing_bytes - #frame
      self.write_pending = true
      return true
    else
      return nil, message or "agent send failed"
    end
  end
  return true
end

function Client:_dispatch_agent_response(response)
  local pending = response.request_id and self.pending_requests[response.request_id]
  if not pending then
    self:_handle_agent_message(response)
    return
  end

  -- A replay gap is reported as a snapshot before the subscribed response.
  -- It updates the client cursor but does not complete the subscription.
  if response.kind == "snapshot" and pending.expected_kind ~= "snapshot" then
    self:_handle_agent_message(response)
    return
  end

  if response.kind ~= pending.expected_kind and response.kind ~= "error" then
    self.pending_requests[response.request_id] = nil
    pending.request.pending_ids[response.request_id] = nil
    self:_finish_request(pending.request, nil, agent_error("invalid_protocol",
      "unexpected Workbench response kind: " .. tostring(response.kind)))
    return
  end

  self.pending_requests[response.request_id] = nil
  pending.request.pending_ids[response.request_id] = nil
  if response.kind == "error" then
    self:_finish_request(pending.request,
      nil, response.error or agent_error("agent_error", "agent rejected the request"))
    return
  end

  self:_handle_agent_message(response)
  local value, error_result = pending.handler(response)
  if value == PENDING then return end
  self:_finish_request(pending.request, value, error_result)
end

function Client:_fail_agent_requests(error_result)
  if not self.pending_requests then return end
  local requests = {}
  local seen = {}
  for request_id, pending in pairs(self.pending_requests) do
    self.pending_requests[request_id] = nil
    pending.request.pending_ids[request_id] = nil
    if not seen[pending.request] then
      seen[pending.request] = true
      requests[#requests + 1] = pending.request
    end
  end
  for _, request in ipairs(requests) do
    self:_finish_request(request, nil, error_result)
  end
end

function Client:_expire_requests(now)
  if not self.pending_requests then return end
  local expired = {}
  for request_id, pending in pairs(self.pending_requests) do
    if now >= pending.deadline then
      self.pending_requests[request_id] = nil
      pending.request.pending_ids[request_id] = nil
      expired[pending.request] = true
    end
  end
  for request in pairs(expired) do
    self:_finish_request(request, nil, agent_error("timeout",
      "Workbench request timed out"))
  end
end

function Client:_disconnect(message)
  local connection = self.connection
  self.connection = nil
  self.outgoing = {}
  self.outgoing_bytes = 0
  self.write_pending = false
  self.agent_subscribed = false
  if connection then pcall(function() connection:close() end) end
  self:_fail_agent_requests(agent_error("agent_disconnected", message))
end

function Client:_fail_all_requests(error_result)
  local requests = {}
  for _, request in pairs(self.requests) do requests[#requests + 1] = request end
  if self.pending_requests then
    for request_id, pending in pairs(self.pending_requests) do
      self.pending_requests[request_id] = nil
      pending.request.pending_ids[request_id] = nil
    end
  end
  self.completions = {}
  for _, request in ipairs(requests) do
    self:_finish_request(request, nil, error_result)
  end
end

function Client:_agent_message(message, expected_kind)
  local request = self:_new_request(message.request_id)
  local queued, send_message = self:_queue_agent(message, expected_kind, request,
    function(response) return response end)
  if not queued then
    self.requests[request.id] = nil
    return nil, send_message
  end
  local response, wait_message = self:_wait_request(request)
  if not response then return nil, wait_message end
  return response
end

function Client:_wait_request(request)
  while not request.done do
    local _, message = self:poll()
    if not request.done and message and message ~= "timeout"
        and message ~= "would_block" then
      self:cancel(request)
      return nil, agent_error("agent_disconnected", message)
    end
    if not request.done then system.sleep(0.01) end
  end
  return request.value, request.error
end

function Client:_handle_agent_message(message)
  if message.kind == "event" and message.event then
    local event = message.event
    apply_agent_event(self.agent_snapshot, event)
    if (event.type == "output" or event.type == "status" or event.type == "checkpoint")
        and event.runtime_id then
      local events = self.agent_runtime_events[event.runtime_id]
      if not events then
        events = {}
        self.agent_runtime_events[event.runtime_id] = events
      end
      events[#events + 1] = event
    else
      local event_sequence = message.event_sequence or event.event_sequence
      if event_sequence then self.agent_event_cursor = event_sequence end
      for _, callback in ipairs(self.agent_callbacks or {}) do
        pcall(callback, event)
      end
    end
  elseif message.kind == "snapshot" and message.snapshot then
    self.agent_snapshot = message.snapshot
    self.agent_event_cursor = message.snapshot.event_cursor or self.agent_event_cursor
  elseif message.kind == "subscribed" and message.event_cursor then
    self.agent_event_cursor = message.event_cursor
  end
end

function Client:_agent_snapshot()
  local response, message = self:_agent_message(Protocol.request("snapshot",
    next_id("workbench-snapshot"), {}), "snapshot")
  if not response then return nil, message end
  self:_handle_agent_message(response)
  if not self.agent_snapshot then
    return nil, agent_error("snapshot_missing", "agent snapshot response was missing its snapshot field")
  end
  return self.agent_snapshot
end

function Client:_queue_agent_command(request, kind, payload, refresh_snapshot)
  local message = Protocol.request(kind, next_id("workbench-request"), payload)
  local function handle_response(response)
    local result = response.result
      or agent_error("invalid_response", "agent returned no result")
    for _, event in ipairs(result.events or {}) do
      apply_agent_event(self.agent_snapshot, event)
    end
    for _, event in ipairs(result.runtime_events or {}) do
      self:_handle_agent_message(Protocol.request("event", nil, {
        event = event,
      }))
    end
    if result.code == "ok" and refresh_snapshot == true then
      local snapshot_message = Protocol.request("snapshot", next_id("workbench-snapshot"), {})
      local queued, queue_message = self:_queue_agent(snapshot_message, "snapshot", request,
        function(snapshot_response)
          self:_handle_agent_message(snapshot_response)
          if not self.agent_snapshot then
            return nil, agent_error("snapshot_missing",
              "agent snapshot response was missing its snapshot field")
          end
          return result
        end)
      if not queued then return nil, queue_message end
      return PENDING
    end
    return result
  end
  return self:_queue_agent(message, "result", request, handle_response)
end

function Client:_queue_runtime_command(command)
  if not self.connection then
    return nil, agent_error("agent_disconnected", "Workbench agent is disconnected")
  end
  command = copy_command(self, command)
  local queued, queue_message = self:_queue_agent_command(nil, "command", {
    command = command,
  }, false)
  if not queued then return nil, queue_message end
  return true
end

function Client:_agent_execute(command, refresh_snapshot)
  local request, message = self:execute_async(command, nil, {
    refresh_snapshot = refresh_snapshot,
  })
  if not request then
    return type(message) == "table" and message
      or agent_error("agent_error", tostring(message))
  end
  local result, error_result = self:_wait_request(request)
  if result then return result end
  return agent_error(error_result and error_result.code or "agent_error",
    error_result and error_result.message or tostring(error_result))
end

function Client:_agent_execute_batch(commands)
  local request, message = self:execute_batch_async(commands, nil, {})
  if not request then
    return type(message) == "table" and message
      or agent_error("agent_error", tostring(message))
  end
  local result, error_result = self:_wait_request(request)
  if result then return result end
  return agent_error(error_result and error_result.code or "agent_error",
    error_result and error_result.message or tostring(error_result))
end

function Client.open(options)
  options = options or {}
  local backend = options.backend or "agent"
  local workspace_id = options.workspace_id or options.workspace or "default"

  if backend == "fake" or backend == "in_process" then
    local storage_path = options.storage_path
    if backend == "in_process" and storage_path ~= nil then
      return nil, "persistent in-process Workbench backends are disabled; use the agent"
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
      request_timeout = options.request_timeout or DEFAULT_REQUEST_TIMEOUT,
      requests = {},
      completions = {},
      closed = false,
    }, Client)
  end

  if backend == "agent" then
    if not transport_available then
      return nil, "Workbench agent transport is disabled"
    end
    local verify_storage = options.storage_path ~= nil or options.endpoint == nil
    local storage_path = options.storage_path or default_storage_path(workspace_id)
    if type(storage_path) ~= "string" or storage_path == "" then
      return nil, "Workbench agent storage path is unavailable"
    end
    local data_dir = options.data_dir or path_directory(storage_path, USERDIR or ".")
    local endpoint = options.endpoint or default_agent_endpoint(
      options.user_dir or USERDIR or data_dir, workspace_id)
    local connection, connect_message = connect_or_start_agent(options, endpoint,
      data_dir, storage_path, workspace_id)
    if not connection then
      return nil, connect_message or "Unable to connect to Workbench agent"
    end
    local client = setmetatable({
      connection = connection,
      backend = backend,
      workspace_id = workspace_id,
      storage_path = storage_path,
      endpoint = endpoint,
      closed = false,
      agent_callbacks = {},
      agent_event_cursor = 0,
      agent_runtime_events = {},
      request_timeout = options.request_timeout or DEFAULT_REQUEST_TIMEOUT,
      requests = {},
      pending_requests = {},
      completions = {},
      outgoing = {},
      outgoing_bytes = 0,
      write_pending = false,
    }, Client)
    local hello_options = {
        workspace_id = workspace_id,
        protocol_major = Protocol.major,
        protocol_minor = Protocol.minor,
        capabilities = { event_replay = true, event_cursors = true },
      }
    if verify_storage then hello_options.storage_path = storage_path end
    local hello, message = client:_agent_message(Protocol.request("hello",
      next_id("workbench-hello"), hello_options), "hello_result")
    if not hello then
      connection:close()
      return nil, message and message.message or "Workbench agent handshake failed"
    end
    if not hello.ok then
      connection:close()
      return nil, hello.error and hello.error.message or "Workbench agent rejected the handshake"
    end
    local compatibility, compatibility_message = Protocol.compatibility(hello)
    if not compatibility then
      connection:close()
      return nil, compatibility_message
    end
    client.agent_protocol = compatibility
    client.agent_capabilities = hello.capabilities or {}
    client.agent_capability_versions = hello.capability_versions or {}
    client.agent_snapshot, message = client:_agent_snapshot()
    if not client.agent_snapshot then
      connection:close()
      if type(message) == "table" then
        return nil, message.message or "Workbench agent did not return a snapshot"
      end
      return nil, message and tostring(message) or "Workbench agent did not return a snapshot"
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
    request_timeout = options.request_timeout or DEFAULT_REQUEST_TIMEOUT,
    requests = {},
    completions = {},
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

function Client:providers()
  local snapshot = self:snapshot()
  return snapshot and snapshot.providers or {}
end

function Client:execute_async(command, callback, options)
  options = options or {}
  if callback ~= nil and type(callback) ~= "function" then
    return nil, agent_error("invalid_callback", "Workbench request callback must be a function")
  end
  if self.closed then
    return nil, agent_error("closed", "Workbench client is closed")
  end
  if self.connection == nil and self.handle == nil and self.service == nil then
    return nil, agent_error("agent_disconnected", "Workbench client is unavailable")
  end

  command = copy_command(self, command)
  local request = self:_new_request(next_id("workbench-request"), callback, options)
  local function complete_immediately(method)
    self:_schedule_work(request, method)
  end

  if self.service then
    complete_immediately(function() return self.service:execute(command) end)
  elseif self.connection then
    local queued, message = self:_queue_agent_command(request, "command",
      { command = command }, options.refresh_snapshot == true)
    if not queued then
      self.requests[request.id] = nil
      return nil, message
    end
  else
    complete_immediately(function() return self.handle:execute(command) end)
  end
  return request
end

function Client:execute(command, callback, options)
  if type(callback) == "table" and options == nil then
    options, callback = callback, nil
  end
  if type(callback) == "function" then
    return self:execute_async(command, callback, options)
  end
  if self.closed then
    return { code = "closed", message = "Workbench client is closed" }
  end
  local request, message = self:execute_async(command, nil, options)
  if not request then return message end
  local result, error_result = self:_wait_request(request)
  return result or error_result or agent_error("client_error", "Workbench request failed")
end

function Client:execute_batch_async(commands, callback, options)
  options = options or {}
  if callback ~= nil and type(callback) ~= "function" then
    return nil, agent_error("invalid_callback", "Workbench request callback must be a function")
  end
  if self.closed then
    return nil, agent_error("closed", "Workbench client is closed")
  end
  if type(commands) ~= "table" or #commands == 0 then
    return nil, agent_error("invalid_command", "command batch must not be empty")
  end

  local prepared = {}
  local snapshot = self:snapshot()
  local revision = snapshot and snapshot.revision
  if revision == nil then
    return nil, agent_error("client_error", "Workbench snapshot is unavailable")
  end
  for index, command in ipairs(commands) do
    if type(command) ~= "table" then
      return nil, agent_error("invalid_command", "command batch entries must be tables")
    end
    local value = copy_command(self, command)
    if command.expected_revision == nil then
      value.expected_revision = revision + index - 1
    end
    prepared[#prepared + 1] = value
  end

  local request = self:_new_request(next_id("workbench-batch"), callback, options)
  local function complete_immediately(method)
    self:_schedule_work(request, method)
  end

  if self.service then
    complete_immediately(function() return self.service:execute_batch(prepared) end)
  elseif self.connection then
    local queued, message = self:_queue_agent_command(request, "batch",
      { commands = prepared }, options.refresh_snapshot == true)
    if not queued then
      self.requests[request.id] = nil
      return nil, message
    end
  else
    complete_immediately(function()
      local results = {}
      for _, command in ipairs(prepared) do
        local result = self.handle:execute(command)
        results[#results + 1] = result
        if result.code ~= "ok" then
          return {
            code = result.code,
            message = result.message,
            results = results,
          }
        end
      end
      return { code = "ok", revision = self:snapshot().revision, results = results }
    end)
  end
  return request
end

function Client:execute_batch(commands, callback, options)
  if type(callback) == "table" and options == nil then
    options, callback = callback, nil
  end
  if type(callback) == "function" then
    return self:execute_batch_async(commands, callback, options)
  end
  if self.closed then
    return { code = "closed", message = "Workbench client is closed" }
  end
  local request, message = self:execute_batch_async(commands, nil, options)
  if not request then return message end
  local result, error_result = self:_wait_request(request)
  return result or error_result or agent_error("client_error", "Workbench batch failed")
end

function Client:cancel(request_or_id)
  local request = type(request_or_id) == "table" and request_or_id
    or self.requests[request_or_id]
  if not request then return false, agent_error("not_found", "Workbench request not found") end
  if request.done then return false, agent_error("already_done", "Workbench request is complete") end

  for request_id in pairs(request.pending_ids) do
    if self.pending_requests then self.pending_requests[request_id] = nil end
    request.pending_ids[request_id] = nil
  end
  self:_finish_request(request, nil, agent_error("cancelled", "Workbench request was cancelled"))
  return true
end

function Client:on_event(callback)
  if self.service then return self.service:subscribe(callback) end
  if self.connection then
    self.agent_callbacks[#self.agent_callbacks + 1] = callback
    if not self.agent_subscribed then
      self.agent_subscribed = true
      local subscription_id = next_id("workbench-subscribe")
      local request = self:_new_request(subscription_id, function(_, error_result)
        if error_result then
          self.agent_subscribed = false
          self.agent_subscription_error = error_result
        end
      end, {})
      local queued, message = self:_queue_agent(Protocol.request("subscribe",
        subscription_id, {
          workspace_id = self.workspace_id,
          after_event_sequence = self.agent_event_cursor,
        }), "subscribed", request, function(response)
          return response
        end)
      if not queued then
        self.requests[request.id] = nil
        self.agent_subscribed = false
        table.remove(self.agent_callbacks)
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
  if self.service then
    self.service:poll()
    return self:_drain_completions()
  end
  if self.connection then
    local count = self:_drain_completions()
    local flushed, flush_message = self:_flush_outgoing()
    if not flushed then
      self:_disconnect(flush_message)
      return count, flush_message
    end
    self:_expire_requests(system.get_time())
    while true do
      local received, frame, message = pcall(function()
        return self.connection:receive(0)
      end)
      if not received then
        self:_disconnect(frame)
        return count, frame
      end
      if not frame then
        if message ~= "timeout" and message ~= "would_block" then
          self:_disconnect(message or "Workbench agent disconnected")
        end
        self:_expire_requests(system.get_time())
        return count, message
      end
      local response, decode_message = Protocol.decode(frame)
      if not response then
        local error_result = agent_error("invalid_protocol", decode_message)
        self:_disconnect(decode_message)
        return count, error_result
      end
      self:_dispatch_agent_response(response)
      count = count + 1
    end
  end
  local count = self:_drain_completions()
  if self.handle then
    local polled = self.handle:poll()
    return count + (type(polled) == "number" and polled or 0), polled
  end
  return count
end

function Client:write_runtime(runtime_id, data)
  if self.handle and self.handle.write_runtime then
    return self.handle:write_runtime(runtime_id, data)
  end
  if self.connection then
    local queued, message = self:_queue_runtime_command({
      type = "runtime.input", runtime_id = runtime_id, data = data,
    })
    return queued == true, message
  end
  return true
end

function Client:write_runtime_async(runtime_id, data)
  if self.handle and self.handle.write_runtime then
    return self.handle:write_runtime(runtime_id, data)
  end
  if self.connection then
    local queued, message = self:_queue_runtime_command({
      type = "runtime.input", runtime_id = runtime_id, data = data,
    })
    return queued == true, message
  end
  return true
end

function Client:start_runtime(runtime_id, options)
  if self.handle and self.handle.start_runtime then
    return self.handle:start_runtime(runtime_id, options or {})
  end
  if not self.connection then return true end
  options = options or {}
  local result = self:_agent_execute {
    type = "runtime.start",
    runtime_id = runtime_id,
    resource_id = runtime_id,
    columns = options.columns,
    rows = options.rows,
    shell = options.shell,
    command = options.command,
    args = options.args,
    cwd = options.cwd,
    environment = options.environment,
    executable = options.executable,
    prompt = options.prompt,
    model = options.model,
    agent = options.agent,
    sandbox = options.sandbox,
    approval_policy = options.approval_policy,
    profile = options.profile,
    auto = options.auto,
    term = options.term,
    scrollback_limit = options.scrollback_limit,
    external_session_id = options.external_session_id,
    execution_policy = options.execution_policy,
  }
  return result.code == "ok", result
end

function Client:start_runtime_async(runtime_id, options, callback)
  if self.handle and self.handle.start_runtime then
    return self.handle:start_runtime(runtime_id, options or {})
  end
  if not self.connection then return true end
  options = options or {}
  return self:execute_async({
    type = "runtime.start",
    runtime_id = runtime_id,
    resource_id = runtime_id,
    columns = options.columns,
    rows = options.rows,
    shell = options.shell,
    command = options.command,
    args = options.args,
    cwd = options.cwd,
    environment = options.environment,
    executable = options.executable,
    prompt = options.prompt,
    model = options.model,
    agent = options.agent,
    sandbox = options.sandbox,
    approval_policy = options.approval_policy,
    profile = options.profile,
    auto = options.auto,
    term = options.term,
    scrollback_limit = options.scrollback_limit,
    external_session_id = options.external_session_id,
    execution_policy = options.execution_policy,
  }, callback, { refresh_snapshot = false })
end

function Client:resize_runtime(runtime_id, columns, rows)
  if self.handle and self.handle.resize_runtime then
    return self.handle:resize_runtime(runtime_id, columns, rows)
  end
  if self.connection then
    local result = self:_agent_execute({
      type = "runtime.resize", runtime_id = runtime_id,
      columns = columns, rows = rows,
    }, false)
    return result.code == "ok", result
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

function Client:resize_runtime_async(runtime_id, columns, rows)
  if self.handle and self.handle.resize_runtime then
    return self.handle:resize_runtime(runtime_id, columns, rows)
  end
  if self.connection then
    local queued, message = self:_queue_runtime_command {
      type = "runtime.resize", runtime_id = runtime_id,
      columns = columns, rows = rows,
    }
    return queued == true, message
  end
  return true
end

function Client:stop_runtime(runtime_id, options)
  if self.handle and self.handle.stop_runtime then
    return self.handle:stop_runtime(runtime_id, options or {})
  end
  if self.connection then
    local result = self:_agent_execute({
      type = "runtime.stop", runtime_id = runtime_id,
    })
    return result.code == "ok", result
  end
  local result = self:execute {
    type = "terminal.status",
    operation_id = next_id("runtime-stop-" .. runtime_id),
    terminal_id = runtime_id,
    status = "stopped",
  }
  return result.code == "ok", result
end

function Client:stop_runtime_async(runtime_id, options, callback)
  if self.handle and self.handle.stop_runtime then
    return self.handle:stop_runtime(runtime_id, options or {})
  end
  if not self.connection then return true end
  return self:execute_async({
    type = "runtime.stop", runtime_id = runtime_id,
  }, callback, { refresh_snapshot = false })
end

function Client:detach_runtime(runtime_id)
  if self.handle and self.handle.detach_runtime then
    return self.handle:detach_runtime(runtime_id)
  end
  if self.connection then return true end
  return true
end

function Client:request_runtime_output(runtime_id, offset)
  if self.handle and self.handle.request_runtime_output then
    return self.handle:request_runtime_output(runtime_id, offset)
  end
  if self.connection then
    local result = self:_agent_execute({
      type = "runtime.replay", runtime_id = runtime_id, offset = offset or 0,
    }, false)
    if result.code ~= "ok" then return false, result end
    return true, result
  end
  return false, "runtime replay is not available"
end

function Client:request_runtime_output_async(runtime_id, offset, callback)
  if self.handle and self.handle.request_runtime_output then
    return self.handle:request_runtime_output(runtime_id, offset)
  end
  if self.connection then
    return self:execute_async({
      type = "runtime.replay", runtime_id = runtime_id, offset = offset or 0,
    }, callback, { refresh_snapshot = false })
  end
  return false, "runtime replay is not available"
end

function Client:poll_runtime_events(runtime_id)
  if self.handle and self.handle.poll_runtime_events then
    return self.handle:poll_runtime_events(runtime_id)
  end
  if self.connection then
    local _, message = self:poll()
    local events = self.agent_runtime_events[runtime_id] or {}
    self.agent_runtime_events[runtime_id] = {}
    if not self.connection then
      events[#events + 1] = {
        type = "status",
        runtime_id = runtime_id,
        status = "error",
        message = type(message) == "table" and message.message
          or tostring(message or "Workbench agent disconnected"),
      }
    end
    return events
  end
  return {}
end

function Client:terminal_session(resource_id, options)
  local snapshot = self:snapshot()
  for _, resource in ipairs(snapshot.terminals or {}) do
    if resource.id == resource_id then
      if self.connection then
        local request, start_message = self:start_runtime_async(resource_id, options or {},
          function(result, error_result)
            if error_result or not result or result.code ~= "ok" then
              resource.status = "failed"
            end
          end)
        if not request then
          return nil, start_message and (start_message.message or start_message.code)
            or "unable to queue Workbench runtime start"
        end
        resource.status = resource.status or "starting"
      end
      local WorkbenchSession = require "plugins.workbench.terminal_session"
      return WorkbenchSession(self, resource, options)
    end
  end
  return nil, "Workbench terminal resource not found: " .. tostring(resource_id)
end

function Client:close()
  self:_fail_all_requests(agent_error("closed", "Workbench client is closed"))
  if self.connection then
    -- Closing is best effort. Never wait for a blocked transport while
    -- tearing down the client.
    if not self.write_pending and #self.outgoing == 0 then
      pcall(function()
        self.connection:send(Protocol.encode(Protocol.request("close", nil, {})))
      end)
    end
    self.connection:close()
    self.connection = nil
    self.outgoing = {}
    self.outgoing_bytes = 0
    self.write_pending = false
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

Client.default_agent_endpoint = default_agent_endpoint
Client.path_identity = path_identity

return Client
