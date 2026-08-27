local validation = {}
local Policy = require "plugins.workbench.policy"

-- These limits are deliberately shared by every entry point (in-process,
-- agent, and future providers). They keep privileged runtime fields bounded
-- before a provider or native process sees them.
validation.limits = {
  id = 256,
  title = 4096,
  operation_id = 256,
  workspace_id = 256,
  path = 4096,
  string = 1024 * 1024,
  argument_count = 256,
  environment_count = 256,
  batch_count = 128,
  input_bytes = 1024 * 1024,
  history_bytes = 1024 * 1024 * 1024,
  checkpoint_interval_bytes = 64 * 1024 * 1024,
  metadata_depth = 8,
  metadata_bytes = 1024 * 1024,
  provider_config_bytes = 1024 * 1024,
  terminal_columns = 1000,
  terminal_rows = 1000,
  scrollback_lines = 1000000,
}

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

local function bounded_string(value, field, maximum, allow_empty)
  if type(value) ~= "string" or (not allow_empty and value == "") then
    return nil, field .. " must be a " .. (allow_empty and "string" or "non-empty string")
  end
  if #value > maximum then
    return nil, field .. " exceeds the maximum length of " .. tostring(maximum)
  end
  return true
end

local function optional_string(value, field, maximum)
  if value == nil then return true end
  return bounded_string(value, field, maximum, true)
end

local function optional_integer(value, field, minimum, maximum)
  if value == nil then return true end
  if not is_integer(value) then return nil, field .. " must be an integer" end
  if minimum and value < minimum then
    return nil, field .. " must be at least " .. tostring(minimum)
  end
  if maximum and value > maximum then
    return nil, field .. " must be at most " .. tostring(maximum)
  end
  return true
end

local function table_size(value, depth, seen)
  if type(value) ~= "table" then
    if type(value) == "string" then return #value end
    return 8
  end
  if depth > validation.limits.metadata_depth then return nil, "metadata is too deep" end
  seen = seen or {}
  if seen[value] then return nil, "metadata must not be cyclic" end
  seen[value] = true
  local total = 0
  for key, item in pairs(value) do
    local key_size, key_message = table_size(key, depth + 1, seen)
    if not key_size then return nil, key_message end
    local item_size, item_message = table_size(item, depth + 1, seen)
    if not item_size then return nil, item_message end
    total = total + key_size + item_size
    if total > validation.limits.metadata_bytes then
      return nil, "metadata exceeds the maximum size of "
        .. tostring(validation.limits.metadata_bytes) .. " bytes"
    end
  end
  seen[value] = nil
  return total
end

local function validate_metadata(value, field, maximum)
  if type(value) ~= "table" then return nil, field .. " must be a table" end
  local size, message = table_size(value, 0)
  if not size then return nil, field .. " " .. message end
  if size > maximum then
    return nil, field .. " exceeds the maximum size of " .. tostring(maximum) .. " bytes"
  end
  return true
end

local function validate_execution_policy(value, field)
  local ok, message = validate_metadata(value, field, validation.limits.metadata_bytes)
  if not ok then return nil, message end
  return Policy.validate(value, field)
end

local function validate_array(value, field, maximum, item_check)
  if value == nil then return true end
  if type(value) ~= "table" then return nil, field .. " must be an array" end
  if #value > maximum then
    return nil, field .. " exceeds the maximum count of " .. tostring(maximum)
  end
  for index, item in ipairs(value) do
    local ok, message = item_check(item, field .. "[" .. tostring(index) .. "]")
    if not ok then return nil, message end
  end
  return true
end

local function validate_environment(value, field)
  if value == nil then return true end
  if type(value) ~= "table" then return nil, field .. " must be a map" end
  local count = 0
  for key, item in pairs(value) do
    count = count + 1
    if count > validation.limits.environment_count then
      return nil, field .. " exceeds the maximum count of "
        .. tostring(validation.limits.environment_count)
    end
    local ok, message = bounded_string(key, field .. " key", validation.limits.string, false)
    if not ok then return nil, message end
    ok, message = bounded_string(item, field .. " value", validation.limits.string, true)
    if not ok then return nil, message end
  end
  return true
end

local function field(command, nested, name)
  if nested and nested[name] ~= nil then return nested[name] end
  return command[name]
end

local function validate_runtime_start(command)
  local limits = validation.limits
  local source = command.runtime or command
  local ok, message
  for _, name in ipairs { "runtime_id", "resource_id", "terminal_id", "shell", "command", "term" } do
    ok, message = optional_string(source[name], "runtime." .. name,
      name == "term" and limits.string or limits.path)
    if not ok then return nil, message end
  end
  ok, message = optional_string(source.cwd, "runtime.cwd", limits.path)
  if not ok then return nil, message end
  for _, name in ipairs { "columns", "cols" } do
    ok, message = optional_integer(source[name], "runtime." .. name, 1,
      limits.terminal_columns)
    if not ok then return nil, message end
  end
  ok, message = optional_integer(source.rows, "runtime.rows", 1, limits.terminal_rows)
  if not ok then return nil, message end
  for _, name in ipairs { "max_history_bytes", "checkpoint_interval_bytes" } do
    ok, message = optional_integer(source[name], "runtime." .. name, 1,
      name == "max_history_bytes" and limits.history_bytes
        or limits.checkpoint_interval_bytes)
    if not ok then return nil, message end
  end
  ok, message = validate_array(source.args or source.arguments, "runtime.args",
    limits.argument_count, function(item, item_field)
      return bounded_string(item, item_field, limits.string, true)
    end)
  if not ok then return nil, message end
  ok, message = validate_environment(source.environment, "runtime.environment")
  if not ok then return nil, message end
  if source.external_session_id ~= nil then
    ok, message = optional_string(source.external_session_id,
      "runtime.external_session_id", limits.id)
    if not ok then return nil, message end
  end
  if source.execution_policy ~= nil then
    ok, message = validate_execution_policy(source.execution_policy,
      "runtime.execution_policy")
    if not ok then return nil, message end
  end
  ok, message = optional_integer(source.scrollback_limit,
    "runtime.scrollback_limit", 1, limits.scrollback_lines)
  if not ok then return nil, message end
  return true
end

local function validate_runtime_command(command)
  local limits = validation.limits
  local ok, message = bounded_string(command.runtime_id, "runtime.runtime_id",
    limits.id, false)
  if command.type == "runtime.start" or command.type == "runtime.restart" then
    return validate_runtime_start(command)
  end
  if not ok then return nil, message end
  if command.type == "runtime.input" then
    return bounded_string(command.data, "runtime.data", limits.input_bytes, true)
  elseif command.type == "runtime.delete_history" then
    return true
  elseif command.type == "runtime.resize" then
    ok, message = optional_integer(command.columns or command.cols,
      "runtime.columns", 1, limits.terminal_columns)
    if not ok then return nil, message end
    return optional_integer(command.rows, "runtime.rows", 1, limits.terminal_rows)
  elseif command.type == "runtime.replay" then
    return optional_integer(command.offset, "runtime.offset", 0)
  end
  return true
end

local function validate_runtime_config(config, field_name)
  if type(config) ~= "table" then return true end
  local ok, message = optional_integer(config.max_history_bytes,
    field_name .. ".max_history_bytes", 1, validation.limits.history_bytes)
  if not ok then return nil, message end
  ok, message = optional_integer(config.checkpoint_interval_bytes,
    field_name .. ".checkpoint_interval_bytes", 1,
    validation.limits.checkpoint_interval_bytes)
  if not ok then return nil, message end
  ok, message = optional_integer(config.scrollback_limit,
    field_name .. ".scrollback_limit", 1, validation.limits.scrollback_lines)
  if not ok then return nil, message end
  if config.execution_policy ~= nil then
    ok, message = validate_execution_policy(config.execution_policy,
      field_name .. ".execution_policy")
    if not ok then return nil, message end
  end
  ok, message = validate_array(config.args or config.arguments, field_name .. ".args",
    validation.limits.argument_count, function(item, item_field)
      return bounded_string(item, item_field, validation.limits.string, true)
    end)
  if not ok then return nil, message end
  return validate_environment(config.environment or config.env, field_name .. ".environment")
end

local function validate_command_fields(command)
  local limits = validation.limits
  local command_type = command.type
  local nested
  local ok, message

  if command_type == "workspace.create" or command_type == "workspace.rename" then
    return bounded_string(command.name or command.title, "workspace.name",
      limits.title, false)
  elseif command_type == "collection.create" then
    ok, message = optional_string(command.id, "collection.id", limits.id)
    if not ok then return nil, message end
    return bounded_string(command.title, "collection.title", limits.title, false)
  elseif command_type == "collection.rename" or command_type == "collection.move"
      or command_type == "collection.update" then
    nested = command.collection
    ok, message = optional_string(field(command, nested, "collection_id"),
      "collection.collection_id", limits.id)
    if not ok then return nil, message end
    ok, message = optional_string(field(command, nested, "id"), "collection.id", limits.id)
    if not ok then return nil, message end
    ok, message = optional_string(field(command, nested, "title"),
      "collection.title", limits.title)
    if not ok then return nil, message end
    return optional_integer(field(command, nested, "order"), "collection.order")
  elseif command_type == "collection.archive" or command_type == "collection.delete" then
    return bounded_string(command.collection_id or command.id, "collection.id",
      limits.id, false)
  elseif command_type == "task.create" then
    ok, message = optional_string(command.id, "task.id", limits.id)
    if not ok then return nil, message end
    ok, message = bounded_string(command.title, "task.title", limits.title, false)
    if not ok then return nil, message end
    return optional_string(command.collection_id, "task.collection_id", limits.id)
  elseif command_type == "task.update" or command_type == "task.move" then
    nested = command.task
    ok, message = optional_string(field(command, nested, "task_id"),
      "task.task_id", limits.id)
    if not ok then return nil, message end
    ok, message = optional_string(field(command, nested, "id"), "task.id", limits.id)
    if not ok then return nil, message end
    ok, message = optional_string(field(command, nested, "title"), "task.title", limits.title)
    if not ok then return nil, message end
    return optional_string(field(command, nested, "collection_id"),
      "task.collection_id", limits.id)
  elseif command_type == "task.archive" or command_type == "task.delete" then
    return bounded_string(command.task_id or command.id, "task.id", limits.id, false)
  elseif command_type == "resource.create" or command_type == "terminal.create" then
    nested = command.resource or command.terminal
    local source = nested or command
    ok, message = optional_string(source.id, "resource.id", limits.id)
    if not ok then return nil, message end
    ok, message = bounded_string(source.title, "resource.title", limits.title, false)
    if not ok then return nil, message end
    ok, message = optional_string(source.provider, "resource.provider", limits.id)
    if not ok then return nil, message end
    ok, message = validate_metadata(source.config or {}, "resource.config",
      limits.provider_config_bytes)
    if not ok then return nil, message end
    ok, message = validate_runtime_config(source.config, "resource.config")
    if not ok then return nil, message end
    ok, message = optional_integer(source.cols or source.columns, "resource.cols",
      1, limits.terminal_columns)
    if not ok then return nil, message end
    return optional_integer(source.rows, "resource.rows", 1, limits.terminal_rows)
  elseif command_type == "resource.update" or command_type == "resource.attach"
      or command_type == "resource.detach" or command_type == "terminal.update"
      or command_type == "terminal.status" then
    nested = command.resource or command.terminal
    local source = nested or command
    ok, message = optional_string(source.resource_id or source.terminal_id or source.id,
      "resource.id", limits.id)
    if not ok then return nil, message end
    ok, message = optional_string(source.title, "resource.title", limits.title)
    if not ok then return nil, message end
    ok, message = optional_integer(source.cols or source.columns, "resource.cols",
      1, limits.terminal_columns)
    if not ok then return nil, message end
    ok, message = optional_integer(source.rows, "resource.rows", 1, limits.terminal_rows)
    if not ok then return nil, message end
    if source.config ~= nil then
      ok, message = validate_metadata(source.config, "resource.config",
        limits.provider_config_bytes)
      if not ok then return nil, message end
      ok, message = validate_runtime_config(source.config, "resource.config")
      if not ok then return nil, message end
    end
    return true
  elseif command_type == "resource.archive" or command_type == "resource.delete"
      or command_type == "terminal.delete" then
    return bounded_string(command.resource_id or command.terminal_id or command.id,
      "resource.id", limits.id, false)
  elseif command_type == "runtime.update" then
    nested = command.runtime
    local source = nested or command
    ok, message = bounded_string(source.runtime_id or source.id, "runtime.id", limits.id, false)
    if not ok then return nil, message end
    if source.metadata ~= nil then
      ok, message = validate_metadata(source.metadata, "runtime.metadata",
        limits.metadata_bytes)
      if not ok then return nil, message end
    end
    for _, name in ipairs { "capabilities", "execution_policy" } do
      if source[name] ~= nil then
        if name == "execution_policy" then
          ok, message = validate_execution_policy(source[name], "runtime." .. name)
        else
          ok, message = validate_metadata(source[name], "runtime." .. name,
            limits.metadata_bytes)
        end
        if not ok then return nil, message end
      end
    end
    for _, name in ipairs { "resource_id", "history_path", "checkpoint_path",
      "started_at", "ended_at", "provider" } do
      ok, message = optional_string(source[name], "runtime." .. name,
        name == "provider" and limits.id
          or name:match("path") and limits.path or limits.string)
      if not ok then return nil, message end
    end
    if source.status ~= nil then
      local statuses = {
        starting = true, running = true, stopping = true, stopped = true,
        exited = true, interrupted = true, recovering = true, failed = true,
      }
      if not statuses[source.status] then return nil, "runtime.status is invalid" end
    end
    for _, name in ipairs { "pid", "output_bytes", "output_offset", "oldest_offset",
      "newest_offset", "max_history_bytes", "checkpoint_offset" } do
      ok, message = optional_integer(source[name], "runtime." .. name, 0,
        name == "max_history_bytes" and limits.history_bytes or nil)
      if not ok then return nil, message end
    end
    if source.max_history_bytes ~= nil and source.max_history_bytes == 0 then
      return nil, "runtime.max_history_bytes must be positive"
    end
    return true
  elseif command_type == "runtime.start" or command_type == "runtime.restart"
      or command_type == "runtime.stop" or command_type == "runtime.input"
      or command_type == "runtime.resize" or command_type == "runtime.replay"
      or command_type == "runtime.delete_history" then
    return validate_runtime_command(command)
  elseif command_type == "provider.metadata.update" then
    nested = command.provider
    local source = nested or command
    ok, message = bounded_string(source.provider_id or source.id, "provider.id",
      limits.id, false)
    if not ok then return nil, message end
    return validate_metadata(source.metadata, "provider.metadata", limits.metadata_bytes)
  end
  return true
end

function validation.command(command)
  if type(command) ~= "table" then
    return nil, "command must be a table"
  end
  if type(command.type) ~= "string" or command.type == "" then
    return nil, "command.type must be a non-empty string"
  end
  if #command.type > validation.limits.id then
    return nil, "command.type exceeds the maximum length of "
      .. tostring(validation.limits.id)
  end
  if command.operation_id ~= nil then
    local ok, message = bounded_string(command.operation_id, "command.operation_id",
      validation.limits.operation_id, false)
    if not ok then return nil, message end
  end
  if command.workspace_id ~= nil then
    local ok, message = bounded_string(command.workspace_id, "command.workspace_id",
      validation.limits.workspace_id, false)
    if not ok then return nil, message end
  end
  if command.expected_revision ~= nil then
    if not is_integer(command.expected_revision) then
      return nil, "command.expected_revision must be an integer"
    end
    if command.expected_revision < 0 then
      return nil, "command.expected_revision must be non-negative"
    end
  end
  return validate_command_fields(command)
end

function validation.batch(commands)
  if type(commands) ~= "table" or #commands == 0 then
    return nil, "command batch must not be empty"
  end
  if #commands > validation.limits.batch_count then
    return nil, "command batch exceeds the maximum count of "
      .. tostring(validation.limits.batch_count)
  end
  for index, command in ipairs(commands) do
    local ok, message = validation.command(command)
    if not ok then return nil, "command batch entry " .. tostring(index) .. ": " .. message end
  end
  return true
end

function validation.id(value, field)
  field = field or "id"
  if type(value) ~= "string" or value == "" then
    return nil, field .. " must be a non-empty string"
  end
  return true
end

function validation.title(value, field)
  field = field or "title"
  if type(value) ~= "string" or value == "" then
    return nil, field .. " must be a non-empty string"
  end
  return true
end

function validation.integer(value, field)
  field = field or "value"
  if not is_integer(value) then
    return nil, field .. " must be an integer"
  end
  return true
end

return validation
