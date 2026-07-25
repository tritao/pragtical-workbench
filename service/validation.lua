local validation = {}

local function is_integer(value)
  return type(value) == "number" and value == math.floor(value)
end

function validation.command(command)
  if type(command) ~= "table" then
    return nil, "command must be a table"
  end
  if type(command.type) ~= "string" or command.type == "" then
    return nil, "command.type must be a non-empty string"
  end
  if command.operation_id ~= nil and type(command.operation_id) ~= "string" then
    return nil, "command.operation_id must be a string"
  end
  if command.workspace_id ~= nil and type(command.workspace_id) ~= "string" then
    return nil, "command.workspace_id must be a string"
  end
  if command.expected_revision ~= nil
      and not is_integer(command.expected_revision) then
    return nil, "command.expected_revision must be an integer"
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

