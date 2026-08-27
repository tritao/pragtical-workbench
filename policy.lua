local policy = {}

local approvals = {
  prompt = true,
  auto = true,
}

local sandboxes = {
  ["read-only"] = true,
  workspace = true,
  full = true,
}

local permission_levels = {
  deny = true,
  prompt = true,
  allow = true,
}

local permissions = {
  filesystem = true,
  network = true,
  process = true,
}

local fields = {
  approval = true,
  sandbox = true,
  permissions = true,
}

local function invalid(field, message)
  return nil, field .. " " .. message
end

function policy.validate(value, field)
  field = field or "execution_policy"
  if value == nil then return true end
  if type(value) ~= "table" then
    return invalid(field, "must be a table")
  end

  for name in pairs(value) do
    if not fields[name] then
      return invalid(field .. "." .. tostring(name), "is not a supported field")
    end
  end

  if value.approval ~= nil then
    if type(value.approval) ~= "string" or not approvals[value.approval] then
      return invalid(field .. ".approval", "must be one of: prompt, auto")
    end
  end
  if value.sandbox ~= nil then
    if type(value.sandbox) ~= "string" or not sandboxes[value.sandbox] then
      return invalid(field .. ".sandbox",
        "must be one of: read-only, workspace, full")
    end
  end
  if value.permissions ~= nil then
    if type(value.permissions) ~= "table" then
      return invalid(field .. ".permissions", "must be a table")
    end
    for name, level in pairs(value.permissions) do
      if not permissions[name] then
        return invalid(field .. ".permissions." .. tostring(name),
          "is not a supported permission")
      end
      if type(level) ~= "string" or not permission_levels[level] then
        return invalid(field .. ".permissions." .. tostring(name),
          "must be one of: deny, prompt, allow")
      end
    end
  end
  return true
end

function policy.normalize(value, field)
  local ok, message = policy.validate(value, field)
  if not ok then return nil, message end
  local result = {}
  for name, item in pairs(value or {}) do
    if name == "permissions" then
      result.permissions = {}
      for permission, level in pairs(item) do
        result.permissions[permission] = level
      end
    else
      result[name] = item
    end
  end
  return result
end

function policy.merge(base, override, field)
  local result, message = policy.normalize(base, field)
  if not result then return nil, message end
  local requested
  requested, message = policy.normalize(override, field)
  if not requested then return nil, message end
  for name, item in pairs(requested) do
    if name == "permissions" then
      result.permissions = result.permissions or {}
      for permission, level in pairs(item) do
        result.permissions[permission] = level
      end
    else
      result[name] = item
    end
  end
  return result
end

return policy
