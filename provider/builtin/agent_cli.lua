local function invalid(message)
  return nil, { code = "provider_invalid_resource", message = message }
end

local Runtime = require "plugins.workbench.provider.runtime"

local function optional_string(value, field)
  if value ~= nil and (type(value) ~= "string" or value == "") then
    return invalid(field .. " must be a non-empty string")
  end
  return true
end

local function arguments(value, field)
  if value == nil then return {} end
  if type(value) ~= "table" then return invalid(field .. " must be an array") end
  local result = {}
  for index = 1, #value do
    if type(value[index]) ~= "string" then
      return invalid(field .. " must contain only strings")
    end
    result[index] = value[index]
  end
  return result
end

local function config_error(config)
  if config == nil then config = {} end
  if type(config) ~= "table" then return invalid("resource.config must be a table") end
  for _, field in ipairs { "executable", "prompt", "model", "agent", "sandbox",
      "approval_policy", "profile" } do
    local ok, message = optional_string(config[field], "resource.config." .. field)
    if not ok then return nil, message end
  end
  local args, message = arguments(config.args, "resource.config.args")
  if not args then return nil, message end
  if config.auto ~= nil and type(config.auto) ~= "boolean" then
    return invalid("resource.config.auto must be a boolean")
  end
  return true
end

local function add_flag(result, flag, value)
  result[#result + 1] = flag
  if value ~= nil then result[#result + 1] = value end
end

local function make(spec)
  local Provider = {
    id = spec.id,
    version = 1,
    kinds = { terminal = true },
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
        ["resource.created"] = true,
        ["resource.updated"] = true,
        ["runtime.output"] = true,
        ["runtime.status"] = true,
        ["runtime.exited"] = true,
        ["runtime.failed"] = true,
      },
    },
  }

  function Provider.create_resource(value)
    if value.kind ~= nil and value.kind ~= "terminal" then
      return invalid(Provider.id .. " only creates terminal resources")
    end
    local ok, message = config_error(value.config)
    if not ok then return nil, message end
    return {
      kind = "terminal",
      provider = Provider.id,
      config = value.config or {},
      status = value.status or "stopped",
      cols = value.cols or value.columns or 80,
      rows = value.rows or 24,
    }
  end

  function Provider.update_resource(_, patch)
    local ok, message = config_error(patch.config)
    if not ok then return nil, message end
    return {}
  end

  function Provider.runtime_spec(resource, command)
    local config = resource.config or {}
    local ok, message = config_error(config)
    if not ok then return nil, message end

    local executable = command.executable or config.executable or spec.executable
    ok, message = optional_string(executable, "runtime.executable")
    if not ok then return nil, message end
    local args, args_message = arguments(config.args, "resource.config.args")
    if not args then return nil, args_message end
    local extra, extra_message = arguments(command.args, "runtime.args")
    if not extra then return nil, extra_message end
    for _, argument in ipairs(extra) do args[#args + 1] = argument end

    local model = command.model or config.model
    local agent = command.agent or config.agent
    local sandbox = command.sandbox or config.sandbox
    local approval_policy = command.approval_policy or config.approval_policy
    local profile = command.profile or config.profile
    for field, value in pairs {
      model = model, agent = agent, sandbox = sandbox,
      approval_policy = approval_policy, profile = profile,
    } do
      ok, message = optional_string(value, "runtime." .. field)
      if not ok then return nil, message end
    end

    if spec.model_flag and model then add_flag(args, spec.model_flag, model) end
    if spec.agent_flag and agent then add_flag(args, spec.agent_flag, agent) end
    if spec.sandbox_flag and sandbox then add_flag(args, spec.sandbox_flag, sandbox) end
    if spec.approval_flag and approval_policy then
      add_flag(args, spec.approval_flag, approval_policy)
    end
    if spec.profile_flag and profile then add_flag(args, spec.profile_flag, profile) end
    if spec.auto_flag and (command.auto or config.auto) then add_flag(args, spec.auto_flag) end

    local prompt = command.prompt or config.prompt
    ok, message = optional_string(prompt, "runtime.prompt")
    if not ok then return nil, message end
    if prompt then
      if spec.prompt_flag then add_flag(args, spec.prompt_flag, prompt)
      else args[#args + 1] = prompt end
    end

    local columns = command.columns or command.cols or resource.cols or 80
    local rows = command.rows or resource.rows or 24
    if type(columns) ~= "number" or columns < 1 or columns ~= math.floor(columns) then
      return invalid("runtime.columns must be a positive integer")
    end
    if type(rows) ~= "number" or rows < 1 or rows ~= math.floor(rows) then
      return invalid("runtime.rows must be a positive integer")
    end
    local environment = command.environment or config.environment or config.env
    if environment ~= nil and type(environment) ~= "table" then
      return invalid("runtime.environment must be a table")
    end
    return {
      command = executable,
      shell = executable,
      args = args,
      cwd = command.cwd or config.cwd,
      environment = environment,
      columns = columns,
      rows = rows,
      scrollback_limit = command.scrollback_limit or config.scrollback_limit or 10000,
      term = command.term or config.term or "xterm-256color",
    }
  end

  function Provider.runtime_metadata(resource, spec)
    return {
      provider = Provider.id,
      executable = spec.command,
      cwd = spec.cwd,
    }
  end

  function Provider.validate_metadata(metadata)
    if type(metadata) ~= "table" then
      return invalid("provider metadata must be a table")
    end
    return true
  end

  return Runtime.attach(Provider)
end

return make
