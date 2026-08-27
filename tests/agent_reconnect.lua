local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")

test.describe("Workbench agent reconnect", function()
  test.test("reloads the persisted workspace after the agent restarts", function()
    local client = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-test",
    })
    local snapshot = client:snapshot()
    test.equal(snapshot.revision, 2)
    test.equal(snapshot.collections[1].id, "agent-collection")
    client:close()
  end)
end)
