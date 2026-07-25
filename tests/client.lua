local test = require "core.test"
local Client = require "plugins.workbench.client"

local workspace_sequence = 0

local function new_workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "client-test-" .. tostring(workspace_sequence)
end

test.describe("Workbench client", function()
  local client

  test.before_each(function()
    client = assert(Client.open {
      backend = "fake",
      workspace_id = new_workspace_id(),
    })
  end)

  test.after_each(function()
    client:close()
  end)

  test.test("opens without the native Workbench module", function()
    test.ok(client:is_open())
    test.equal(client.backend, "fake")
    test.equal(client:snapshot().revision, 0)
  end)

  test.test("fills the workspace and revision fields for commands", function()
    local events = {}
    client:on_event(function(event)
      events[#events + 1] = event
    end)

    local result = client:execute {
      type = "collection.create",
      id = "collection-client",
      title = "Client tests",
    }
    test.equal(result.code, "ok")
    test.equal(result.revision, 1)
    test.equal(result.events[1].workspace_id, client.workspace_id)
    test.equal(#events, 1)

    local task = client:execute {
      type = "task.create",
      id = "task-client",
      title = "Exercise the adapter",
      collection_id = "collection-client",
    }
    test.equal(task.code, "ok")
    test.equal(task.revision, 2)
    test.equal(#client:snapshot().tasks, 1)
  end)

  test.test("shares in-process state through the same service boundary", function()
    local workspace_id = new_workspace_id()
    local first = assert(Client.open {
      backend = "in_process",
      workspace_id = workspace_id,
    })
    local second = assert(Client.open {
      backend = "fake",
      workspace_id = workspace_id,
    })

    local result = first:execute {
      type = "collection.create",
      id = "collection-shared",
      title = "Shared state",
    }
    test.equal(result.code, "ok")
    test.equal(second:snapshot().collections[1].title, "Shared state")

    first:close()
    second:close()
  end)

  test.test("returns a stable closed-client error", function()
    client:close()
    local result = client:execute {
      type = "collection.create",
      id = "collection-closed",
      title = "Should not be created",
    }
    test.equal(result.code, "closed")
    test.ok(not client:is_open())
  end)
end)

