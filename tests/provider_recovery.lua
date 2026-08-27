local test = require "core.test"
local ProviderRegistry = require "plugins.workbench.provider"

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

local function new_backend()
  return {
    online = true,
    next_session = 0,
    sessions = {},
    shutdowns = 0,
    capabilities = {
      actions = {
        ["runtime.start"] = true,
        ["runtime.stop"] = true,
        ["runtime.restart"] = true,
        ["runtime.input"] = true,
        ["runtime.resize"] = true,
      },
    },
  }
end

local function new_provider(backend)
  local Provider = {
    id = "test.remote",
    version = 1,
    kinds = { session = true },
    default_kinds = { session = true },
    capabilities = {
      runtime = true,
      persistent = true,
      replay = true,
      actions = copy(backend.capabilities.actions),
      events = {
        ["runtime.output"] = true,
        ["runtime.status"] = true,
        ["runtime.exited"] = true,
      },
    },
  }

  local function online()
    if not backend.online then
      return failure("provider_backend_unavailable", "remote runtime backend is offline")
    end
    return true
  end

  local function session(runtime_record)
    local id = runtime_record and runtime_record.external_session_id
    local value = id and backend.sessions[id]
    if not value then
      return failure("provider_session_not_found", "external runtime session was not found")
    end
    return value, id
  end

  function Provider.create_resource(value)
    return {
      kind = "session",
      provider = Provider.id,
      config = value.config or {},
      status = value.status or "stopped",
    }
  end

  function Provider.update_resource()
    return {}
  end

  function Provider.runtime_spec(_, command)
    return {
      external_session_id = command.external_session_id,
    }
  end

  function Provider.runtime_metadata(_, spec)
    return {
      provider = Provider.id,
      provider_version = Provider.version,
      external_session_id = spec.external_session_id,
      capabilities = copy(Provider.capabilities),
    }
  end

  function Provider.validate_metadata(metadata)
    return type(metadata) == "table"
  end

  function Provider.available()
    if not backend.online then
      return false, {
        code = "provider_backend_unavailable",
        message = "remote runtime backend is offline",
      }
    end
    return true
  end

  function Provider.create(_, spec)
    local ok, message = online()
    if not ok then return nil, message end
    backend.next_session = backend.next_session + 1
    local id = spec.external_session_id or ("remote-" .. backend.next_session)
    backend.sessions[id] = { status = "running", input = nil, resize = nil }
    return { external_session_id = id }
  end

  function Provider.attach(_, runtime_record)
    local ok, message = online()
    if not ok then return nil, message end
    local value, id = session(runtime_record)
    if not value then return nil, id end
    return { external_session_id = runtime_record.external_session_id, session = value }
  end

  function Provider.recover(resource, runtime_record, context)
    if runtime_record.provider_version ~= Provider.version then
      return failure("provider_version_mismatch", "remote runtime provider version changed")
    end
    for action, required in pairs((runtime_record.capabilities or {}).actions or {}) do
      if required and not backend.capabilities.actions[action] then
        return failure("provider_capability_downgrade",
          "remote runtime no longer supports " .. action)
      end
    end
    return Provider.attach(resource, runtime_record, context)
  end

  function Provider.start(resource, spec, context)
    return Provider.create(resource, spec, context)
  end

  function Provider.stop(_, runtime)
    local ok, message = online()
    if not ok then return nil, message end
    local value, session_message = session(runtime)
    if not value then return nil, session_message end
    value.status = "stopped"
    return true
  end

  function Provider.restart(resource, runtime, spec, context)
    local stopped, message = Provider.stop(resource, runtime, context)
    if not stopped then return nil, message end
    return Provider.start(resource, spec, context)
  end

  function Provider.send_input(_, runtime, data)
    local ok, message = online()
    if not ok then return nil, message end
    local value, session_message = session(runtime)
    if not value then return nil, session_message end
    value.input = data
    return #data
  end

  function Provider.action(_, runtime, action, parameters)
    local ok, message = online()
    if not ok then return nil, message end
    local value, session_message = session(runtime)
    if not value then return nil, session_message end
    if action ~= "resize" then
      return failure("provider_action_unsupported", "remote runtime action is unsupported")
    end
    value.resize = { columns = parameters.columns, rows = parameters.rows }
    return true
  end

  function Provider.refresh_status(_, runtime)
    local ok, message = online()
    if not ok then return nil, message end
    local value, session_message = session(runtime)
    if not value then return nil, session_message end
    return { status = value.status, output = "" }
  end

  function Provider.shutdown()
    backend.shutdowns = backend.shutdowns + 1
    return true
  end

  return Provider
end

test.describe("Workbench provider recovery", function()
  test.test("survives backend loss and resumes after the backend returns", function()
    local backend = new_backend()
    local provider = new_provider(backend)
    local registry = ProviderRegistry.new { provider }
    local resource = assert(registry:create_resource { kind = "session" })
    local spec = assert(registry:runtime_spec(resource, {
      external_session_id = "remote-survives-workbench",
    }))
    local runtime = assert(registry:start(resource, spec, {}))

    backend.online = false
    local available, available_message = registry:available(resource, {})
    test.not_ok(available)
    test.equal(available_message.code, "provider_backend_unavailable")
    local status, status_message = registry:refresh_status(resource, runtime, {})
    test.is_nil(status)
    test.equal(status_message.code, "provider_backend_unavailable")

    backend.online = true
    test.ok(registry:available(resource, {}))
    status = assert(registry:refresh_status(resource, runtime, {}))
    test.equal(status.status, "running")
    test.equal(registry:send_input(resource, runtime, "hello", {}), 5)
  end)

  test.test("reattaches sessions after Workbench restart and rejects unsafe recovery", function()
    local backend = new_backend()
    local first = new_provider(backend)
    local registry = ProviderRegistry.new { first }
    local resource = assert(registry:create_resource { kind = "session" })
    local runtime = assert(registry:start(resource, {
      external_session_id = "remote-persistent-session",
    }, {}))
    local metadata = assert(registry:runtime_metadata(resource, {
      external_session_id = runtime.external_session_id,
    }))
    local record = {
      external_session_id = metadata.external_session_id,
      provider_version = metadata.provider_version,
      capabilities = copy(metadata.capabilities),
    }

    local restarted = ProviderRegistry.new { new_provider(backend) }
    local restarted_resource = assert(restarted:create_resource { kind = "session" })
    local attached = assert(restarted:attach(restarted_resource, record, {}))
    test.equal(attached.external_session_id, runtime.external_session_id)
    local recovered = assert(restarted:recover(restarted_resource, record, {}))
    test.equal(recovered.external_session_id, runtime.external_session_id)

    local stale = copy(record)
    stale.external_session_id = "remote-missing-session"
    local stale_runtime, stale_message = restarted:recover(restarted_resource, stale, {})
    test.is_nil(stale_runtime)
    test.equal(stale_message.code, "provider_session_not_found")

    local incompatible = copy(record)
    incompatible.provider_version = record.provider_version + 1
    local incompatible_runtime, incompatible_message =
      restarted:recover(restarted_resource, incompatible, {})
    test.is_nil(incompatible_runtime)
    test.equal(incompatible_message.code, "provider_version_mismatch")

    backend.capabilities.actions["runtime.resize"] = nil
    local downgraded_runtime, downgraded_message =
      restarted:recover(restarted_resource, record, {})
    test.is_nil(downgraded_runtime)
    test.equal(downgraded_message.code, "provider_capability_downgrade")

    backend.capabilities.actions["runtime.resize"] = true
    recovered = assert(restarted:recover(restarted_resource, record, {}))
    test.equal(recovered.external_session_id, runtime.external_session_id)
    test.ok(restarted:shutdown({}))
    test.equal(backend.shutdowns, 1)
  end)
end)
