local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")

local function find_provider(providers, id)
  for _, provider in ipairs(providers) do
    if provider.id == id then return provider end
  end
end

test.describe("Workbench agent client", function()
  local client

  test.before_each(function()
    client = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-test",
    })
  end)

  test.after_each(function()
    client:close()
  end)

  test.test("handshakes, executes commands, and persists snapshots", function()
    local events = {}
    assert(client:on_event(function(event) events[#events + 1] = event end))
    local result
    local request_error
    local request = assert(client:execute({
      type = "collection.create",
      id = "agent-collection",
      title = "Agent collection",
    }, function(value, error_result)
      result = value
      request_error = error_result
    end))
    test.ok(not request:is_done())
    local deadline = system.get_time() + 2
    while not request:is_done() and system.get_time() < deadline do
      client:poll()
      if not request:is_done() then system.sleep(0.01) end
    end
    test.ok(request:is_done())
    test.equal(result.code, "ok")
    test.is_nil(request_error)
    test.equal(client:snapshot().revision, 1)
    test.equal(#events, 1)
    test.equal(events[1].type, "collection.created")
    test.not_nil(find_provider(client:providers(), "builtin.shell"))

    local resource = client:execute {
      type = "resource.create",
      operation_id = "agent-runtime-resource",
      expected_revision = 1,
      id = "agent-runtime-resource",
      title = "Recoverable runtime",
      kind = "terminal",
      status = "starting",
    }
    test.equal(resource.code, "ok")
    local runtime = client:execute {
      type = "runtime.update",
      operation_id = "agent-runtime-running",
      expected_revision = 2,
      runtime = {
        id = "agent-runtime",
        resource_id = "agent-runtime-resource",
        status = "running",
      },
    }
    test.equal(runtime.code, "ok")
  end)

  test.test("serves multiple clients through one authoritative service", function()
    local second = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-test",
    })
    local first_events, second_events = {}, {}
    assert(client:on_event(function(event) first_events[#first_events + 1] = event end))
    assert(second:on_event(function(event) second_events[#second_events + 1] = event end))
    local first_result, second_result
    local first_request = assert(client:execute({
      type = "collection.create",
      id = "agent-multi-first",
      title = "First concurrent collection",
    }, function(result) first_result = result end))
    local second_request = assert(second:execute({
      type = "collection.create",
      id = "agent-multi-second",
      title = "Second concurrent collection",
    }, function(result) second_result = result end))

    local deadline = system.get_time() + 2
    while (not first_request:is_done() or not second_request:is_done())
        and system.get_time() < deadline do
      client:poll()
      second:poll()
      if not first_request:is_done() or not second_request:is_done() then
        system.sleep(0.01)
      end
    end

    test.ok(first_request:is_done())
    test.ok(second_request:is_done())
    test.ok(first_result and second_result)
    local successful = (first_result.code == "ok" and 1 or 0)
      + (second_result.code == "ok" and 1 or 0)
    test.equal(successful, 1)
    local conflicts = (first_result.code == "revision_conflict" and 1 or 0)
      + (second_result.code == "revision_conflict" and 1 or 0)
    test.equal(conflicts, 1)
    test.equal(#first_events, 1)
    test.equal(#second_events, 1)
    second:close()
  end)
end)
