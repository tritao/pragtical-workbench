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
      backend = "in_process",
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

  test.test("completes callback requests from poll", function()
    local callback_result
    local callback_error
    local request = assert(client:execute_async({
      type = "collection.create",
      id = "collection-async",
      title = "Async client",
    }, function(result, error_result)
      callback_result = result
      callback_error = error_result
    end))

    test.ok(not request:is_done())
    test.is_nil(callback_result)
    test.equal(client:poll(), 1)
    test.ok(request:is_done())
    test.equal(callback_result.code, "ok")
    test.is_nil(callback_error)
    local value, error_result = request:result()
    test.same(value, callback_result)
    test.is_nil(error_result)
  end)

  test.test("cancels a request before its completion is delivered", function()
    local callback_called = false
    local request = assert(client:execute_async({
      type = "collection.create",
      id = "collection-cancelled",
      title = "Cancelled client request",
    }, function()
      callback_called = true
    end))

    local cancelled, error_result = client:cancel(request)
    test.equal(cancelled, true)
    test.is_nil(error_result)
    local value, request_error = request:result()
    test.is_nil(value)
    test.equal(request_error.code, "cancelled")
    test.ok(callback_called)
    client:poll()
    test.equal(#client:snapshot().collections, 0)
  end)
end)
