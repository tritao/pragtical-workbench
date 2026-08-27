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

local RUNTIME_METHODS = {
  "available", "create", "attach", "recover", "start", "stop", "restart",
  "send_input", "action", "refresh_status", "shutdown",
}

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
  return result, message
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
  for _, method in ipairs(RUNTIME_METHODS) do
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

function Registry:_runtime_call(resource, method, ...)
  local provider, message = self:for_resource(resource)
  if not provider then return nil, message end
  local result, result_message = call(provider, method, resource, ...)
  return result, result_message, provider
end

function Registry:available(resource, context)
  local available, message = self:_runtime_call(resource, "available", context)
  if available == nil then return nil, message end
  if type(available) ~= "boolean" then
    return failure("provider_contract", resource.provider .. ".available() must return a boolean")
  end
  return available, message
end

function Registry:create(resource, spec, context)
  return self:_runtime_call(resource, "create", spec, context)
end

function Registry:attach(resource, runtime_record, context)
  return self:_runtime_call(resource, "attach", runtime_record, context)
end

function Registry:recover(resource, runtime_record, context)
  return self:_runtime_call(resource, "recover", runtime_record, context)
end

function Registry:start(resource, spec, context)
  return self:_runtime_call(resource, "start", spec, context)
end

function Registry:stop(resource, runtime, context)
  return self:_runtime_call(resource, "stop", runtime, context)
end

function Registry:restart(resource, runtime, spec, context)
  return self:_runtime_call(resource, "restart", runtime, spec, context)
end

function Registry:send_input(resource, runtime, data, context)
  return self:_runtime_call(resource, "send_input", runtime, data, context)
end

function Registry:action(resource, runtime, action, parameters, context)
  return self:_runtime_call(resource, "action", runtime, action, parameters, context)
end

function Registry:refresh_status(resource, runtime, context)
  local status, message, provider = self:_runtime_call(resource, "refresh_status", runtime, context)
  if not status then return nil, message end
  if type(status) ~= "table" then
    return failure("provider_contract", provider.id .. ".refresh_status() must return a table")
  end
  if status.status ~= "running" and status.status ~= "exited" then
    return failure("provider_contract", provider.id
      .. ".refresh_status() returned an invalid status")
  end
  if status.output ~= nil and type(status.output) ~= "string" then
    return failure("provider_contract", provider.id
      .. ".refresh_status() output must be a string")
  end
  return status, provider
end

function Registry:capabilities(resource, context)
  local provider, message = self:for_resource(resource)
  if not provider then return nil, message end
  if type(provider.capabilities) == "function" then
    local capabilities, capability_message = call(provider, "capabilities", resource, context)
    if not capabilities then return nil, capability_message end
    if type(capabilities) ~= "table" then
      return failure("provider_contract", provider.id .. ".capabilities() must return a table")
    end
    return copy(capabilities), provider
  end
  return copy(provider.capabilities), provider
end

function Registry:shutdown(context)
  local providers = {}
  for _, provider in pairs(self.providers) do providers[#providers + 1] = provider end
  table.sort(providers, function(left, right) return left.id < right.id end)
  for _, provider in ipairs(providers) do
    local ok, message = call(provider, "shutdown", context)
    if not ok then return nil, message end
  end
  return true
end

-- Providers may use this optional hook for bounded background work that is
-- not tied to a currently running runtime (for example, a best-effort abort
-- request issued while the agent is committing a stopped transition).
function Registry:poll(context)
  local providers = {}
  for _, provider in pairs(self.providers) do providers[#providers + 1] = provider end
  table.sort(providers, function(left, right) return left.id < right.id end)
  for _, provider in ipairs(providers) do
    if type(provider.poll) == "function" then
      local ok, message = pcall(provider.poll, context)
      if not ok then return failure("provider_error", provider.id .. " poll failed: " .. tostring(message)) end
    end
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
  local shell = require "plugins.workbench.provider.builtin.shell"
  local codex = require "plugins.workbench.provider.builtin.codex"
  local opencode = require "plugins.workbench.provider.builtin.opencode"
  return Registry.new {
    shell,
    codex,
    opencode,
  }
end

return Registry
