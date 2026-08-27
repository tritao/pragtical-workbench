local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")

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
  end)
end)
