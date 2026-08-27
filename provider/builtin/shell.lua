local Runtime = require "plugins.workbench.provider.runtime"

local Shell = {
  id = "builtin.shell",
  version = 1,
  kinds = { terminal = true },
  default_kinds = { terminal = true },
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

local function invalid(message)
  return nil, { code = "provider_invalid_resource", message = message }
end

local function positive_integer(value, field)
  if type(value) ~= "number" or value < 1 or value ~= math.floor(value) then
    return invalid(field .. " must be a positive integer")
  end
  return true
end

local function optional_table(value, field)
  if value ~= nil and type(value) ~= "table" then
    return invalid(field .. " must be a table")
  end
  return true
end

function Shell.create_resource(value)
  if value.kind ~= nil and value.kind ~= "terminal" then
    return invalid("builtin.shell only creates terminal resources")
  end
  local ok, message = optional_table(value.config, "resource.config")
  if not ok then return nil, message end
  return {
    kind = "terminal",
    provider = Shell.id,
    config = value.config or {},
    status = value.status or "stopped",
    cols = value.cols or value.columns or 80,
    rows = value.rows or 24,
  }
end

function Shell.update_resource(_, patch)
  local ok, message = optional_table(patch.config, "resource.config")
  if not ok then return nil, message end
  return {}
end

function Shell.runtime_spec(resource, command)
  local config = resource.config or {}
  local shell = command.shell or command.command or config.shell or config.command
    or os.getenv("SHELL") or "sh"
  if type(shell) ~= "string" or shell == "" then
    return invalid("runtime shell must be a non-empty string")
  end
  local args = command.args or command.arguments or config.args or config.arguments
  local environment = command.environment or config.environment or config.env
  local ok, message = optional_table(args, "runtime.args")
  if not ok then return nil, message end
  ok, message = optional_table(environment, "runtime.environment")
  if not ok then return nil, message end

  local columns = command.columns or command.cols or resource.cols or config.columns or 80
  local rows = command.rows or resource.rows or config.rows or 24
  ok, message = positive_integer(columns, "runtime.columns")
  if not ok then return nil, message end
  ok, message = positive_integer(rows, "runtime.rows")
  if not ok then return nil, message end

  return {
    command = shell,
    shell = shell,
    args = args,
    cwd = command.cwd or config.cwd,
    environment = environment,
    columns = columns,
    rows = rows,
    scrollback_limit = command.scrollback_limit or config.scrollback_limit or 10000,
    term = command.term or config.term or "xterm-256color",
  }
end

function Shell.runtime_metadata(_, spec)
  return { provider = Shell.id, shell = spec.command }
end

function Shell.validate_metadata(metadata)
  if type(metadata) ~= "table" then
    return invalid("provider metadata must be a table")
  end
  return true
end

return Runtime.attach(Shell)
