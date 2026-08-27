local Registry = {}
Registry.__index = Registry

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[copy(key, seen)] = copy(item, seen)
  end
  return result
end

local function failure(code, message)
  return nil, { code = code, message = message }
end

local function valid_id(value)
  return type(value) == "string" and value ~= ""
end

local function sorted_keys(values)
  local result = {}
  for key, value in pairs(values or {}) do
    if value then result[#result + 1] = key end
  end
  table.sort(result)
  return result
end

local function call(provider, method, ...)
  local implementation = provider[method]
  if type(implementation) ~= "function" then
    return failure("provider_contract", provider.id .. " is missing " .. method .. "()")
  end
  local ok, result, message = pcall(implementation, ...)
  if not ok then
    return failure("provider_error", provider.id .. " " .. method .. " failed: "
      .. tostring(result))
  end
  if result == nil then
    if type(message) == "table" then return nil, message end
    return failure("provider_rejected", tostring(message or (provider.id .. " rejected " .. method)))
  end
  return result
end

function Registry.new(providers)
  local registry = setmetatable({ providers = {}, defaults = {} }, Registry)
  for _, provider in ipairs(providers or {}) do
    local ok, message = registry:register(provider)
    assert(ok, message and message.message or message)
  end
  return registry
end

function Registry:register(provider)
  if type(provider) ~= "table" then
    return failure("provider_contract", "provider must be a table")
  end
  if not valid_id(provider.id) then
    return failure("provider_contract", "provider.id must be a non-empty string")
  end
  if self.providers[provider.id] then
    return failure("provider_conflict", "provider already registered: " .. provider.id)
  end
  if type(provider.version) ~= "number" or provider.version < 1
      or provider.version ~= math.floor(provider.version) then
    return failure("provider_contract", provider.id .. ".version must be a positive integer")
  end
  if type(provider.kinds) ~= "table" or #sorted_keys(provider.kinds) == 0 then
    return failure("provider_contract", provider.id .. ".kinds must not be empty")
  end
  if type(provider.capabilities) ~= "table" then
    return failure("provider_contract", provider.id .. ".capabilities must be a table")
  end
  for _, method in ipairs { "create_resource", "update_resource", "runtime_spec" } do
    if type(provider[method]) ~= "function" then
      return failure("provider_contract", provider.id .. " is missing " .. method .. "()")
    end
  end
  if type(provider.runtime_metadata) ~= "function" then
    return failure("provider_contract", provider.id .. " is missing runtime_metadata()")
  end
  if type(provider.validate_metadata) ~= "function" then
    return failure("provider_contract", provider.id .. " is missing validate_metadata()")
  end

  self.providers[provider.id] = provider
  for kind in pairs(provider.default_kinds or {}) do
    if provider.kinds[kind] then self.defaults[kind] = provider.id end
  end
  return true
end

function Registry:get(provider_id)
  local provider = self.providers[provider_id]
  if not provider then
    return failure("provider_not_found", "provider not found: " .. tostring(provider_id))
  end
  return provider
end

function Registry:resolve(provider_id, kind)
  if provider_id == nil or provider_id == "" then
    provider_id = self.defaults[kind]
  end
  if not provider_id then
    return failure("provider_required", "no provider is registered for resource kind: "
      .. tostring(kind))
  end
  local provider, message = self:get(provider_id)
  if not provider then return nil, message end
  if kind and not provider.kinds[kind] then
    return failure("provider_kind_unsupported", provider.id .. " does not support resource kind "
      .. tostring(kind))
  end
  return provider
end

function Registry:for_resource(resource)
  return self:resolve(resource and resource.provider, resource and resource.kind)
end

function Registry:allows(resource, action)
  local provider, message = self:for_resource(resource)
  if not provider then return nil, message end
  local actions = provider.capabilities.actions or {}
  if not actions[action] then
    return failure("provider_action_unsupported", provider.id .. " does not support " .. action)
  end
  return true
end

function Registry:create_resource(value, context)
  local provider, message = self:resolve(value.provider, value.kind or "terminal")
  if not provider then return nil, message end
  local normalized, provider_message = call(provider, "create_resource", value, context)
  if not normalized then return nil, provider_message end
  if type(normalized) ~= "table" then
    return failure("provider_contract", provider.id .. " create_resource() must return a table")
  end
  normalized = copy(normalized)
  normalized.provider = provider.id
  normalized.kind = normalized.kind or value.kind
  return normalized, provider
end

function Registry:update_resource(resource, patch, context)
  local provider, message = self:for_resource(resource)
  if not provider then return nil, message end
  local normalized, provider_message = call(provider, "update_resource", resource, patch, context)
  if not normalized then return nil, provider_message end
  if type(normalized) ~= "table" then
    return failure("provider_contract", provider.id .. " update_resource() must return a table")
  end
  return copy(normalized), provider
end

function Registry:runtime_spec(resource, command, context)
  local provider, message = self:for_resource(resource)
  if not provider then return nil, message end
  if not self:allows(resource, "runtime.start") then
    return failure("provider_action_unsupported", provider.id .. " does not support runtime.start")
  end
  local spec, provider_message = call(provider, "runtime_spec", resource, command, context)
  if not spec then return nil, provider_message end
  if type(spec) ~= "table" then
    return failure("provider_contract", provider.id .. " runtime_spec() must return a table")
  end
  return copy(spec), provider
end

function Registry:runtime_metadata(resource, spec, context)
  local provider, message = self:for_resource(resource)
  if not provider then return nil, message end
  local metadata, provider_message = call(provider, "runtime_metadata", resource, spec, context)
  if not metadata then return nil, provider_message end
  if type(metadata) ~= "table" then
    return failure("provider_contract", provider.id .. " runtime_metadata() must return a table")
  end
  return copy(metadata), provider
end

function Registry:validate_metadata(provider_id, metadata, context)
  local provider, message = self:get(provider_id)
  if not provider then return nil, message end
  local valid, provider_message = call(provider, "validate_metadata", metadata, context)
  if not valid then return nil, provider_message end
  if valid ~= true then
    return failure("provider_contract", provider.id .. " validate_metadata() must return true")
  end
  return true
end

function Registry:describe()
  local providers = {}
  for _, provider in pairs(self.providers) do
    providers[#providers + 1] = {
      id = provider.id,
      version = provider.version,
      kinds = sorted_keys(provider.kinds),
      capabilities = copy(provider.capabilities),
    }
  end
  table.sort(providers, function(left, right) return left.id < right.id end)
  return providers
end

function Registry.default()
  return Registry.new {
    require "plugins.workbench.provider.builtin.shell",
  }
end

return Registry
