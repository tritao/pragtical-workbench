local Http = require "plugins.workbench.provider.opencode_http"
local Policy = require "plugins.workbench.policy"

local OpenCode = {
  id = "builtin.opencode",
  version = 2,
  kinds = { terminal = true },
  default_kinds = {},
  capabilities = {
    resource = { create = true, update = true },
    runtime = true,
    persistent = true,
    replay = true,
    actions = {
      ["resource.create"] = true,
      ["resource.update"] = true,
      ["runtime.start"] = true,
      ["runtime.stop"] = true,
      ["runtime.restart"] = true,
      ["runtime.input"] = true,
      ["runtime.resize"] = true,
      ["runtime.replay"] = true,
    },
    events = {
      ["runtime.output"] = true,
      ["runtime.status"] = true,
      ["runtime.exited"] = true,
      ["runtime.failed"] = true,
    },
  },
  pending = {},
  servers = {},
}

local DEFAULT_SERVER_URL = "http://127.0.0.1:4096"

local function invalid(message)
  return nil, { code = "provider_invalid_resource", message = message }
end

local function failure(code, message)
  return nil, { code = code, message = message }
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function optional_string(value, field)
  if value ~= nil and (type(value) ~= "string" or value == "") then
    return invalid(field .. " must be a non-empty string")
  end
  return true
end

local function optional_boolean(value, field)
  if value ~= nil and type(value) ~= "boolean" then
    return invalid(field .. " must be a boolean")
  end
  return true
end

local function optional_port(value, field)
  if value == nil then return true end
  if type(value) ~= "number" or value < 1 or value > 65535
      or value ~= math.floor(value) then
    return invalid(field .. " must be an integer between 1 and 65535")
  end
  return true
end

local function arguments(value, field)
  if value == nil then return {} end
  if type(value) ~= "table" then return invalid(field .. " must be an array") end
  local result = {}
  for index = 1, #value do
    if type(value[index]) ~= "string" or value[index] == "" then
      return invalid(field .. " must contain only non-empty strings")
    end
    result[index] = value[index]
  end
  return result
end

local function effective_policy(config, command)
  local policy, message = Policy.merge(config.execution_policy,
    command.execution_policy, "runtime.execution_policy")
  if not policy then return nil, message end
  if policy.approval == nil and (command.auto or config.auto) then
    policy.approval = "auto"
  end
  return policy
end

local function config_error(config)
  config = config or {}
  if type(config) ~= "table" then return invalid("resource.config must be a table") end
  for _, field in ipairs {
    "server_url", "executable", "cwd", "model", "agent", "title",
    "server_hostname",
  } do
    local ok, message = optional_string(config[field], "resource.config." .. field)
    if not ok then return nil, message end
  end
  for _, field in ipairs { "manage_server", "auto" } do
    local ok, message = optional_boolean(config[field], "resource.config." .. field)
    if not ok then return nil, message end
  end
  local ok, message = optional_port(config.server_port, "resource.config.server_port")
  if not ok then return nil, message end
  local args, args_message = arguments(config.server_args, "resource.config.server_args")
  if not args then return nil, args_message end
  local policy_ok, policy_message = Policy.validate(config.execution_policy,
    "resource.config.execution_policy")
  if not policy_ok then return invalid(policy_message) end
  return true
end

local function client_for(context, base_url)
  local backend = context and context.opencode
  if backend then
    if type(backend.request) == "function" and type(backend.stream) == "function" then
      return backend
    end
    if type(backend.new) == "function" then
      local ok, client = pcall(backend.new, backend, base_url)
      if ok and client then return client end
    end
    return nil, "OpenCode test transport must implement request() and stream()"
  end
  return Http.new { base_url = base_url }
end

local function request(runtime, method, path, body, tag)
  local result, message = runtime.client:request(method, path, body)
  if not result then return nil, message end
  runtime.request = { value = result, tag = tag }
  return true
end

local function server_process(runtime, context, spec)
  if not spec.manage_server or (context and context.opencode) then return nil end
  local key = spec.server_url .. "\0" .. tostring(spec.cwd or "")
  local existing = OpenCode.servers[key]
  if existing then
    existing.references = existing.references + 1
    return existing.process, false, key
  end
  local native = context.runtime_native
  if type(native) ~= "table" or type(native.new) ~= "function" then
    return nil, "native runtime support is required to manage an OpenCode server"
  end
  local args = { "serve", "--hostname", spec.server_hostname,
    "--port", tostring(spec.server_port) }
  for _, value in ipairs(spec.server_args or {}) do args[#args + 1] = value end
  local ok, process = pcall(native.new, {
    command = spec.command,
    shell = spec.command,
    args = args,
    cwd = spec.cwd,
    environment = spec.environment,
    columns = 80,
    rows = 24,
    term = "xterm-256color",
  })
  if not ok then return nil, tostring(process) end
  if not process then return nil, "OpenCode server process could not be started" end
  OpenCode.servers[key] = { process = process, references = 1 }
  return process, true, key
end

local function make_spec(resource, command, metadata)
  command = command or {}
  metadata = metadata or {}
  local config = resource.config or {}
  local server_url = command.server_url or config.server_url or metadata.server_url
    or DEFAULT_SERVER_URL
  local manage_server = command.manage_server
  if manage_server == nil then manage_server = config.manage_server end
  if manage_server == nil then manage_server = server_url == DEFAULT_SERVER_URL end
  local server_port = command.server_port or config.server_port or metadata.server_port or 4096
  local server_hostname = command.server_hostname or config.server_hostname
    or metadata.server_hostname or "127.0.0.1"
  local executable = command.executable or config.executable or "opencode"
  local policy, message = effective_policy(config, command)
  if not policy then return nil, message end
  local server_args = command.server_args or config.server_args or {}
  if type(server_args) ~= "table" then return nil, "runtime.server_args must be an array" end
  local result = {
    command = executable,
    shell = executable,
    args = {},
    server_args = copy(server_args),
    cwd = command.cwd or config.cwd,
    environment = command.environment or config.environment or config.env,
    columns = command.columns or command.cols or resource.cols or 80,
    rows = command.rows or resource.rows or 24,
    term = command.term or config.term or "xterm-256color",
    server_url = server_url,
    manage_server = manage_server,
    server_port = server_port,
    server_hostname = server_hostname,
    model = command.model or config.model,
    agent = command.agent or config.agent,
    title = command.title or config.title or resource.title,
    prompt = command.prompt or config.prompt,
    external_session_id = command.external_session_id or metadata.external_session_id,
    execution_policy = policy,
  }
  return result
end

local function provider_metadata(spec, session_id)
  return {
    provider = OpenCode.id,
    provider_version = OpenCode.version,
    server_url = spec.server_url,
    server_hostname = spec.server_hostname,
    server_port = spec.server_port,
    manage_server = spec.manage_server,
    model = spec.model,
    agent = spec.agent,
    external_session_id = session_id or spec.external_session_id,
    execution_policy = copy(spec.execution_policy),
  }
end

local function process_event(runtime, event, output)
  local data = event.data
  if type(data) == "string" then
    local ok, decoded = pcall(require("core.json").decode, data)
    if ok and type(decoded) == "table" then data = decoded end
  end
  if type(data) ~= "table" then return end
  local event_type = event.event or data.type
  local properties = data.properties or data
  local part = properties.part or properties
  local session_id = properties.sessionID or properties.sessionId or properties.session_id
    or part.sessionID or part.sessionId or part.session_id
  if session_id and session_id ~= runtime.external_session_id then return end

  if event_type == "message.part.updated" then
    if part.type ~= "text" then return end
    local key = part.id or (part.messageID or "message") .. ":" .. tostring(part.type)
    local delta = properties.delta or part.delta
    if type(delta) == "string" and delta ~= "" then
      output[#output + 1] = delta
      return
    end
    local text = part.text or part.content
    if type(text) ~= "string" then return end
    local previous = runtime.parts[key] or ""
    if text:sub(1, #previous) == previous then
      output[#output + 1] = text:sub(#previous + 1)
    elseif text ~= previous then
      output[#output + 1] = text
    end
    runtime.parts[key] = text
  elseif event_type == "session.error" then
    local error_value = properties.error or properties.message or "OpenCode session failed"
    if type(error_value) == "table" then
      error_value = error_value.data and error_value.data.message
        or error_value.message or error_value.name
        or "OpenCode session failed"
    end
    runtime.error = tostring(error_value)
  elseif event_type == "permission.updated" or event_type == "permission.asked" then
    local permission_id = properties.id or properties.permissionID or properties.permission_id
    if runtime.spec.execution_policy.approval == "auto" and permission_id then
      runtime.pending_permissions[#runtime.pending_permissions + 1] = permission_id
    else
      runtime.permission_pending = true
      output[#output + 1] = "\n[OpenCode permission requested]\n"
    end
  end
end

local function poll_server(runtime)
  if not runtime.server_process then return true end
  local ok, output = pcall(function() return runtime.server_process:poll() end)
  if not ok then return nil, tostring(output) end
  local exited_ok, exited, code, signal = pcall(function()
    return runtime.server_process:exited()
  end)
  if not exited_ok then return nil, tostring(exited) end
  if exited then
    return nil, "OpenCode server exited (code " .. tostring(code or "unknown")
      .. ", signal " .. tostring(signal or "none") .. ")"
  end
  return true
end

local function poll_request(runtime)
  if not runtime.request then return true end
  local request_value = runtime.request.value
  local called, request_ok, result, response = pcall(function()
    return request_value:poll()
  end)
  if not called then
    return nil, { code = "provider_backend_unavailable", message = tostring(request_ok) }
  end
  if request_ok == nil then return false end
  if not request_ok then
    if type(result) == "table" then return nil, result end
    return nil, { code = "provider_backend_unavailable", message = tostring(result) }
  end
  local tag = runtime.request.tag
  runtime.request = nil
  return true, result, response, tag
end

function OpenCode.create_resource(value)
  if value.kind ~= nil and value.kind ~= "terminal" then
    return invalid("builtin.opencode only creates terminal resources")
  end
  local ok, message = config_error(value.config)
  if not ok then return nil, message end
  return {
    kind = "terminal",
    provider = OpenCode.id,
    config = value.config or {},
    status = value.status or "stopped",
    cols = value.cols or value.columns or 80,
    rows = value.rows or 24,
  }
end

function OpenCode.update_resource(_, patch)
  local ok, message = config_error(patch.config)
  if not ok then return nil, message end
  return {}
end

function OpenCode.runtime_spec(resource, command)
  local ok, message = config_error(resource.config)
  if not ok then return nil, message end
  local spec, spec_message = make_spec(resource, command)
  if not spec then return invalid(spec_message) end
  ok, message = optional_string(spec.server_url, "runtime.server_url")
  if not ok then return nil, message end
  ok, message = optional_string(spec.server_hostname, "runtime.server_hostname")
  if not ok then return nil, message end
  ok, message = optional_port(spec.server_port, "runtime.server_port")
  if not ok then return nil, message end
  ok, message = optional_boolean(spec.manage_server, "runtime.manage_server")
  if not ok then return nil, message end
  local server_args, args_message = arguments(spec.server_args, "runtime.server_args")
  if not server_args then return nil, args_message end
  spec.server_args = server_args
  if type(spec.columns) ~= "number" or spec.columns < 1
      or spec.columns ~= math.floor(spec.columns) then
    return invalid("runtime.columns must be a positive integer")
  end
  if type(spec.rows) ~= "number" or spec.rows < 1
      or spec.rows ~= math.floor(spec.rows) then
    return invalid("runtime.rows must be a positive integer")
  end
  return spec
end

function OpenCode.runtime_metadata(_, spec)
  return provider_metadata(spec)
end

function OpenCode.validate_metadata(metadata)
  if type(metadata) ~= "table" then return invalid("provider metadata must be a table") end
  if metadata.provider_version ~= nil and type(metadata.provider_version) ~= "number" then
    return invalid("provider metadata.provider_version must be a number")
  end
  if metadata.external_session_id ~= nil and type(metadata.external_session_id) ~= "string" then
    return invalid("provider metadata.external_session_id must be a string")
  end
  return true
end

function OpenCode.available(_, context)
  if context and context.opencode then return true end
  local loaded, net = pcall(require, "net")
  if not loaded or type(net) ~= "table" then
    return false, { code = "provider_unavailable", message = "agent networking support is unavailable" }
  end
  local command = context and context.command or {}
  local resource = context and context.resource or {}
  local executable = command.executable or (resource.config and resource.config.executable)
    or "opencode"
  local native = context and context.runtime_native
  if native and type(native.available) == "function" then
    local ok, available, message = pcall(native.available, executable)
    if not ok then return false, { code = "provider_runtime_error", message = tostring(available) } end
    if not available then
      return false, { code = "provider_executable_unavailable",
        message = message or ("executable is not available: " .. executable) }
    end
  end
  return true
end

local function new_runtime(resource, spec, context, session_id)
  local client, message = client_for(context, spec.server_url)
  if not client then return failure("provider_backend_unavailable", message) end
  local runtime = {
    client = client,
    spec = spec,
    external_session_id = session_id,
    parts = {},
    pending_inputs = {},
    pending_permissions = {},
    phase = session_id and "attach" or "health",
    startup_polls = session_id and 0 or 20,
    metadata = provider_metadata(spec, session_id),
    closed = false,
  }
  local process, process_owner, process_key = server_process(runtime, context, spec)
  if not process then
    if process_owner then return failure("provider_runtime_error", process_owner) end
  else
    runtime.server_process = process
    runtime.server_owner = process_owner
    runtime.server_key = process_key
  end
  if spec.prompt then runtime.pending_inputs[#runtime.pending_inputs + 1] = spec.prompt end
  runtime.startup_polls = process_owner and (session_id and 0 or 20) or 0
  return runtime
end

function OpenCode.create(resource, spec, context)
  return new_runtime(resource, spec, context)
end

function OpenCode.start(resource, spec, context)
  return new_runtime(resource, spec, context, spec.external_session_id)
end

function OpenCode.attach(resource, runtime_record, context)
  local metadata = runtime_record.metadata or {}
  local spec, message = make_spec(resource, {}, metadata)
  if not spec then return failure("provider_invalid_resource", message) end
  local session_id = runtime_record.external_session_id or metadata.external_session_id
  if not session_id then return failure("provider_session_not_found", "OpenCode session ID is missing") end
  return new_runtime(resource, spec, context, session_id)
end

function OpenCode.recover(resource, runtime_record, context)
  local version = runtime_record.provider_version
    or runtime_record.metadata and runtime_record.metadata.provider_version
  if version and version ~= OpenCode.version then
    return failure("provider_version_mismatch", "OpenCode provider version changed")
  end
  return OpenCode.attach(resource, runtime_record, context)
end

function OpenCode.stop(_, runtime)
  if type(runtime) ~= "table" then return failure("provider_contract", "invalid OpenCode runtime") end
  if runtime.closed then return true end
  runtime.closed = true
  if runtime.event_stream and runtime.event_stream.close then
    pcall(function() runtime.event_stream:close() end)
  end
  if runtime.external_session_id and runtime.client then
    local request_value = runtime.client:request("POST",
      "/session/" .. runtime.external_session_id .. "/abort")
    if request_value then OpenCode.pending[#OpenCode.pending + 1] = request_value end
  end
  if runtime.server_process then
    local managed = OpenCode.servers[runtime.server_key]
    if managed then
      managed.references = managed.references - 1
      if managed.references <= 0 then
        local ok, message = pcall(function() return managed.process:close() end)
        OpenCode.servers[runtime.server_key] = nil
        if not ok then return failure("provider_runtime_error", tostring(message)) end
      end
    end
  end
  return true
end

function OpenCode.restart(resource, runtime, spec, context)
  local stopped, message = OpenCode.stop(resource, runtime, context)
  if not stopped then return nil, message end
  return OpenCode.start(resource, spec, context)
end

function OpenCode.send_input(_, runtime, data)
  if runtime.closed then return failure("provider_runtime_error", "OpenCode runtime is closed") end
  data = data or ""
  runtime.pending_inputs[#runtime.pending_inputs + 1] = data
  return #data
end

function OpenCode.action(_, runtime, action)
  if action == "resize" or action == "runtime.resize" then
    -- OpenCode renders through its server protocol, so PTY dimensions do not
    -- apply. Accepting resize keeps generic terminal views provider-neutral.
    return true
  end
  return failure("provider_action_unsupported", "OpenCode runtime action is unsupported")
end

function OpenCode.refresh_status(_, runtime)
  if runtime.closed then return { status = "exited", output = "" } end
  local server_ok, server_message = poll_server(runtime)
  if not server_ok then return failure("provider_backend_unavailable", server_message) end

  local output = {}
  for _ = 1, 4 do
    if runtime.request then
      local done, result, response, tag = poll_request(runtime)
      if done == false then return { status = "running", output = table.concat(output) } end
      if not done then return nil, result end
      if tag == "health" then
        runtime.phase = "create"
      elseif tag == "create" then
        local id = type(result) == "table" and (result.id or result.sessionID or result.session_id)
        if type(id) ~= "string" or id == "" then
          return failure("provider_backend_unavailable", "OpenCode did not return a session ID")
        end
        runtime.external_session_id = id
        runtime.metadata = provider_metadata(runtime.spec, id)
        runtime.phase = "events"
      elseif tag == "attach" then
        runtime.phase = "events"
      elseif tag == "input" then
        -- A 204 response acknowledges enqueueing the prompt.
      elseif tag == "events" then
        runtime.phase = "streaming"
      end
    end

    if runtime.server_process and runtime.phase == "health" and not runtime.request
        and runtime.startup_polls > 0 then
      runtime.startup_polls = runtime.startup_polls - 1
      return { status = "running", output = "" }
    end

    if runtime.phase == "health" then
      local ok, message = request(runtime, "GET", "/global/health", nil, "health")
      if not ok then return failure("provider_backend_unavailable", message) end
    elseif runtime.phase == "create" then
      local body = {}
      if runtime.spec.title then body.title = runtime.spec.title end
      local ok, message = request(runtime, "POST", "/session", body, "create")
      if not ok then return failure("provider_backend_unavailable", message) end
    elseif runtime.phase == "attach" then
      local ok, message = request(runtime, "GET",
        "/session/" .. runtime.external_session_id, nil, "attach")
      if not ok then return failure("provider_backend_unavailable", message) end
    elseif runtime.phase == "events" then
      local stream, message = runtime.client:stream("/event")
      if not stream then return failure("provider_backend_unavailable", message) end
      runtime.event_stream = stream
      runtime.phase = "streaming"
    elseif runtime.phase == "streaming" then
      if runtime.event_stream then
        local ok, events, message = runtime.event_stream:poll()
        if ok == false then return failure("provider_backend_unavailable", message) end
        if ok == true then
          for _, event in ipairs(events or {}) do process_event(runtime, event, output) end
        end
      end
      if runtime.error then return failure("provider_remote_error", runtime.error) end
      if not runtime.request and #runtime.pending_permissions > 0 then
        local permission_id = table.remove(runtime.pending_permissions, 1)
        local ok, message = request(runtime, "POST",
          "/session/" .. runtime.external_session_id .. "/permissions/"
            .. permission_id, { response = "always" }, "permission")
        if not ok then return failure("provider_backend_unavailable", message) end
      elseif not runtime.request and #runtime.pending_inputs > 0 then
        local input = table.remove(runtime.pending_inputs, 1)
        local body = { parts = { { type = "text", text = input } } }
        if runtime.spec.model then
          local provider_id, model_id = runtime.spec.model:match("^([^/]+)/(.+)$")
          if provider_id and model_id then
            body.model = { providerID = provider_id, modelID = model_id }
          end
        end
        if runtime.spec.agent then body.agent = runtime.spec.agent end
        local ok, message = request(runtime, "POST",
          "/session/" .. runtime.external_session_id .. "/prompt_async", body, "input")
        if not ok then return failure("provider_backend_unavailable", message) end
      end
    end
  end
  return {
    status = "running",
    output = table.concat(output),
    external_session_id = runtime.external_session_id,
    metadata = copy(runtime.metadata),
  }
end

function OpenCode.poll()
  for index = #OpenCode.pending, 1, -1 do
    local request_value = OpenCode.pending[index]
    local ok, done = pcall(function() return request_value:poll() end)
    if not ok or done ~= nil then table.remove(OpenCode.pending, index) end
  end
  return true
end

function OpenCode.shutdown()
  OpenCode.poll()
  OpenCode.pending = {}
  local keys = {}
  for key in pairs(OpenCode.servers) do keys[#keys + 1] = key end
  for _, key in ipairs(keys) do
    local managed = OpenCode.servers[key]
    pcall(function() managed.process:close() end)
    OpenCode.servers[key] = nil
  end
  return true
end

return OpenCode
