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
    test.equal(service:snapshot().revision, 3)
    service:close()

    local reopened_store = assert(Storage.new(path))
    local reopened = Service.new { workspace_id = workspace_id, store = reopened_store }
    local snapshot = reopened:snapshot()
    test.equal(snapshot.revision, 3)
    test.equal(snapshot.collections[1].title, "Persisted collection")
    test.equal(snapshot.tasks[1].title, "Persisted task")
    test.equal(snapshot.terminals[1].config.cwd, "/tmp")
    test.equal(snapshot.terminals[1].config.shell, "/bin/sh")

    local replayed = reopened:execute {
      type = "resource.create",
      operation_id = "persist-resource",
      expected_revision = 3,
      resource = {
        id = "terminal-persisted",
        kind = "terminal",
        title = "Persisted shell",
      },
    }
    test.same(replayed, resource)
    test.equal(reopened:snapshot().revision, 3)
    reopened:close()
    os.remove(path)
  end)
end)
