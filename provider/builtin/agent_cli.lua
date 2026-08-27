local function invalid(message)
  return nil, { code = "provider_invalid_resource", message = message }
end

local Policy = require "plugins.workbench.policy"
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

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function legacy_sandbox(value)
  return ({
    ["workspace-write"] = "workspace",
    ["danger-full-access"] = "full",
  })[value] or value
end

local function legacy_approval(value)
  return ({
    ["on-request"] = "prompt",
    never = "auto",
  })[value] or value
end

local function merge_policy(result, value)
  for key, item in pairs(value or {}) do
    if key == "permissions" then
      result.permissions = result.permissions or {}
      for permission, level in pairs(item) do
        result.permissions[permission] = level
      end
    else
      result[key] = item
    end
  end
end

local function effective_policy(config, command)
  local result = {}
  local configured, message = Policy.normalize(config.execution_policy,
    "resource.config.execution_policy")
  if not configured then return nil, message end
  if configured.sandbox == nil and config.sandbox ~= nil then
    configured.sandbox = legacy_sandbox(config.sandbox)
  end
  if configured.approval == nil and config.approval_policy ~= nil then
    configured.approval = legacy_approval(config.approval_policy)
  end
  merge_policy(result, configured)

  local requested
  requested, message = Policy.normalize(command.execution_policy,
    "runtime.execution_policy")
  if not requested then return nil, message end
  if requested.sandbox == nil and command.sandbox ~= nil then
    requested.sandbox = legacy_sandbox(command.sandbox)
  end
  if requested.approval == nil and command.approval_policy ~= nil then
    requested.approval = legacy_approval(command.approval_policy)
  end
  merge_policy(result, requested)
  local normalized
  normalized, message = Policy.normalize(result, "runtime.execution_policy")
  if not normalized then return nil, message end
  return normalized
end

local function map_policy(policy, spec)
  if spec.map_policy then return spec.map_policy(policy) end
  local result = { permissions = copy(policy.permissions) }
  if policy.sandbox ~= nil then
    if not spec.sandbox_flag then
      return nil, "provider does not support execution_policy.sandbox"
    end
    result.sandbox = (spec.sandbox_values and spec.sandbox_values[policy.sandbox])
      or policy.sandbox
  end
  if policy.approval ~= nil then
    if not spec.approval_flag then
      return nil, "provider does not support execution_policy.approval"
    end
    result.approval = (spec.approval_values and spec.approval_values[policy.approval])
      or policy.approval
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
  local ok, message = Policy.validate(config.execution_policy,
    "resource.config.execution_policy")
  if not ok then return invalid(message) end
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
    local execution_policy, policy_message = effective_policy(config, command)
    if not execution_policy then return invalid(policy_message) end
    local mapped_policy, mapped_message = map_policy(execution_policy, spec)
    if not mapped_policy then return invalid(mapped_message) end
    local sandbox = mapped_policy.sandbox
    local approval_policy = mapped_policy.approval
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
    if spec.auto_flag and (command.auto or config.auto or mapped_policy.auto) then
      add_flag(args, spec.auto_flag)
    end

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
      execution_policy = execution_policy,
      scrollback_limit = command.scrollback_limit or config.scrollback_limit or 10000,
      term = command.term or config.term or "xterm-256color",
    }
  end

  function Provider.runtime_metadata(resource, spec)
    return {
      provider = Provider.id,
      executable = spec.command,
      cwd = spec.cwd,
      execution_policy = spec.execution_policy,
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
