local test = require "core.test"
local json = require "core.json"
local ProviderRegistry = require "plugins.workbench.provider"
local OpenCode = require "plugins.workbench.provider.builtin.opencode"
local Http = require "plugins.workbench.provider.opencode_http"

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

  test.test("drives OpenCode sessions through HTTP and SSE without a PTY", function()
    local backend = {
      next_session = 0,
      sessions = {},
      events = {},
      requests = {},
    }
    local function completed(result, status)
      return {
        poll = function() return true, result, { status = status or 200 } end,
        close = function() end,
      }
    end
    function backend:request(method, path, body)
      self.requests[#self.requests + 1] = { method = method, path = path, body = body }
      if method == "GET" and path == "/global/health" then
        return completed({ healthy = true, version = "test" })
      end
      if method == "POST" and path == "/session" then
        self.next_session = self.next_session + 1
        local id = "opencode-session-" .. tostring(self.next_session)
        self.sessions[id] = true
        return completed({ id = id })
      end
      local session_id = path:match("^/session/([^/]+)$")
      if method == "GET" and session_id then
        if not self.sessions[session_id] then
          return completed({ error = "missing" }, 404)
        end
        return completed({ id = session_id, title = "Workbench" })
      end
      if method == "POST" and path:match("/prompt_async$") then
        local id = path:match("^/session/([^/]+)/prompt_async$")
        self.events[#self.events + 1] = {
          event = "message.part.updated",
          data = json.encode {
            type = "message.part.updated",
            properties = {
              part = {
                id = "part-" .. tostring(#self.events + 1),
                type = "text",
                sessionID = id,
                text = body.parts[1].text,
              },
            },
          },
        }
        return completed(nil, 204)
      end
      if method == "POST" and path:match("/abort$") then
        self.aborted = true
        return completed(true)
      end
      return completed({ error = "unexpected request" }, 500)
    end
    function backend:stream(path)
      test.equal(path, "/event")
      return {
        poll = function()
          local events = self.events
          self.events = {}
          return true, events
        end,
        close = function() end,
      }
    end

    local registry = ProviderRegistry.new { OpenCode }
    local resource = assert(registry:create_resource {
      kind = "terminal",
      provider = "builtin.opencode",
      title = "HTTP OpenCode",
      config = {
        server_url = "http://test-opencode:4096",
        manage_server = false,
        model = "test/model",
      },
    })
    local spec = assert(registry:runtime_spec(resource, {
      execution_policy = { approval = "auto" },
    }))
    test.equal(spec.server_url, "http://test-opencode:4096")
    test.ok(registry:available(resource, { opencode = backend }))
    local runtime = assert(registry:start(resource, spec, { opencode = backend }))
    local status = assert(registry:refresh_status(resource, runtime, { opencode = backend }))
    test.equal(status.status, "running")
    test.equal(status.external_session_id, "opencode-session-1")
    test.equal(status.metadata.provider_version, OpenCode.version)

    test.equal(registry:send_input(resource, runtime, "hello", {}), 5)
    status = assert(registry:refresh_status(resource, runtime, { opencode = backend }))
    test.contains(status.output, "hello")
    test.equal(backend.requests[#backend.requests].path,
      "/session/opencode-session-1/prompt_async")
    test.equal(backend.requests[#backend.requests].body.model.providerID, "test")
    test.equal(backend.requests[#backend.requests].body.model.modelID, "model")

    local record = {
      external_session_id = status.external_session_id,
      metadata = status.metadata,
    }
    assert(registry:stop(resource, runtime, { opencode = backend }))
    assert(registry:poll({ opencode = backend }))
    test.ok(backend.aborted)

    local recovered = assert(registry:recover(resource, record, { opencode = backend }))
    status = assert(registry:refresh_status(resource, recovered, { opencode = backend }))
    test.equal(status.external_session_id, "opencode-session-1")
    test.ok(registry:shutdown({ opencode = backend }))
  end)

  test.test("handles fragmented headers and chunked OpenCode event streams", function()
    local sse = "event: server.connected\ndata: {\"type\":\"server.connected\"}\n\n"
    local responses = {
      table.concat({
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n",
        "Transfer-Encoding: chunked\r\n\r\n",
        "0b\r\n{\"ok\":true}\r\n0\r\n\r\n",
      }, ""),
      table.concat({
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n",
        "Transfer-Encoding: chunked\r\n\r\n",
        string.format("%x\r\n%s\r\n0\r\n\r\n", #sse, sse),
      }, ""),
    }
    local net = {}
    function net.resolve_address()
      return { get_status = function() return "success" end }
    end
    function net.open_tcp()
      local response = table.remove(responses, 1)
      local connection = { chunks = {} }
      for index = 1, #response do connection.chunks[index] = response:sub(index, index) end
      function connection:get_status() return "success" end
      function connection:get_pending_writes() return 0 end
      function connection:write(data) self.request = data return #data end
      function connection:read()
        return table.remove(self.chunks, 1) or ""
      end
      function connection:close() self.closed = true end
      return connection
    end

    local client = Http.new { base_url = "http://test-opencode:4096", net = net }
    local request = assert(client:request("GET", "/global/health"))
    local ok, result
    for _ = 1, 1000 do
      ok, result = request:poll()
      if ok ~= nil then break end
    end
    test.ok(ok)
    test.ok(result.ok)

    local stream = assert(client:stream("/event"))
    local events
    for _ = 1, 1000 do
      ok, events = stream:poll()
      if ok ~= nil and events and #events > 0 then break end
    end
    test.ok(ok)
    test.equal(events[1].event, "server.connected")
  end)
end)
