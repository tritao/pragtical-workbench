local test = require "core.test"
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"

local workspace_sequence = 0

local function new_workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "persistence-test-" .. tostring(workspace_sequence)
end

test.describe("Workbench SQLite persistence", function()
  test.test("restores current state, revisions, and idempotent operations", function()
    local path = os.tmpname()
    os.remove(path)
    local workspace_id = new_workspace_id()

    local store = assert(Storage.new(path))
    local service = Service.new { workspace_id = workspace_id, store = store }
    local collection = service:execute {
      type = "collection.create",
      operation_id = "persist-collection",
      expected_revision = 0,
      id = "collection-persisted",
      title = "Persisted collection",
    }
    test.equal(collection.code, "ok")
    local task = service:execute {
      type = "task.create",
      operation_id = "persist-task",
      expected_revision = 1,
      id = "task-persisted",
      title = "Persisted task",
      collection_id = "collection-persisted",
    }
    test.equal(task.code, "ok")
    local resource = service:execute {
      type = "resource.create",
      operation_id = "persist-resource",
      expected_revision = 2,
      resource = {
        id = "terminal-persisted",
        kind = "terminal",
        title = "Persisted shell",
        config = { cwd = "/tmp", shell = "/bin/sh" },
        status = "starting",
      },
    }
    test.equal(resource.code, "ok")
    local runtime = service:execute {
      type = "runtime.update",
      operation_id = "persist-runtime",
      expected_revision = 3,
      runtime = {
        id = "runtime-persisted",
        resource_id = "terminal-persisted",
        status = "running",
        pid = 1234,
        output_offset = 8192,
        metadata = { shell = "/bin/sh" },
      },
    }
    test.equal(runtime.code, "ok")
    local provider = service:execute {
      type = "provider.metadata.update",
      operation_id = "persist-provider",
      expected_revision = 4,
      provider = {
        id = "builtin.shell",
        metadata = { version = 1 },
      },
    }
    test.equal(provider.code, "ok")
    test.equal(service:snapshot().revision, 5)
    service:close()

    local reopened_store = assert(Storage.new(path))
    local reopened = Service.new { workspace_id = workspace_id, store = reopened_store }
    local snapshot = reopened:snapshot()
    test.equal(snapshot.revision, 5)
    test.equal(snapshot.collections[1].title, "Persisted collection")
    test.equal(snapshot.tasks[1].title, "Persisted task")
    test.equal(snapshot.terminals[1].config.cwd, "/tmp")
    test.equal(snapshot.terminals[1].config.shell, "/bin/sh")
    test.equal(snapshot.runtimes[1].status, "running")
    test.equal(snapshot.runtimes[1].output_offset, 8192)
    test.equal(snapshot.runtimes[1].metadata.shell, "/bin/sh")
    test.equal(snapshot.provider_metadata[1].metadata.version, 1)

    local replayed = reopened:execute {
      type = "resource.create",
      operation_id = "persist-resource",
      expected_revision = 5,
      resource = {
        id = "terminal-persisted",
        kind = "terminal",
        title = "Persisted shell",
      },
    }
    test.same(replayed, resource)
    test.equal(reopened:snapshot().revision, 5)
    reopened:close()
    os.remove(path)
  end)

  test.test("reports replay boundaries and trims old events", function()
    local path = os.tmpname()
    os.remove(path)
    local service = Service.new {
      workspace_id = new_workspace_id(),
      store = assert(Storage.new(path, { event_limit = 2 })),
      event_limit = 2,
    }
    for index = 1, 3 do
      local result = service:execute {
        type = "workspace.rename",
        operation_id = "event-limit-" .. tostring(index),
        expected_revision = index - 1,
        name = "Workspace " .. tostring(index),
      }
      test.equal(result.code, "ok")
    end
    test.equal(service:snapshot().event_offset, 1)
    local events, error_result = service:get_events(0)
    test.equal(events, nil)
    test.equal(error_result.code, "snapshot_required")
    events = assert(service:get_events(1))
    test.equal(#events, 2)
    service:close()

    local reopened = Service.new {
      workspace_id = service.workspace_id,
      store = assert(Storage.new(path, { event_limit = 2 })),
      event_limit = 2,
    }
    test.equal(reopened:snapshot().event_offset, 1)
    events, error_result = reopened:get_events(0)
    test.equal(events, nil)
    test.equal(error_result.code, "snapshot_required")
    events = assert(reopened:get_events(1))
    test.equal(#events, 2)
    reopened:close()
    os.remove(path)
  end)

  test.test("restores state after a failed storage transaction", function()
    local failing_store = {
      load = function() return nil end,
      commit = function() return false, "forced transaction failure" end,
      close = function() end,
    }
    local service = Service.new {
      workspace_id = new_workspace_id(),
      store = failing_store,
    }
    local result = service:execute {
      type = "collection.create",
      operation_id = "failed-transaction",
      expected_revision = 0,
      id = "should-not-persist",
      title = "Should roll back",
    }
    test.equal(result.code, "storage_error")
    test.equal(service:snapshot().revision, 0)
    test.equal(#service:snapshot().collections, 0)
    service:close()
  end)
end)
