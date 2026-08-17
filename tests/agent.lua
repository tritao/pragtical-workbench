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
    local result = client:execute {
      type = "collection.create",
      id = "agent-collection",
      title = "Agent collection",
    }
    test.equal(result.code, "ok")
    test.equal(client:snapshot().revision, 1)
    test.equal(#events, 1)
    test.equal(events[1].type, "collection.created")
  end)
end)
