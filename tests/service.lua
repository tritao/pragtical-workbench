local test = require "core.test"
local Service = require "plugins.workbench.service"

test.describe("Workbench Lua service", function()
  local service

  test.before_each(function()
    service = Service.new { workspace_id = "test-workspace" }
  end)

  test.test("creates a workspace tree and emits typed events", function()
    local seen = {}
    service:subscribe(function(event)
      seen[#seen + 1] = event
    end)

    local collection = service:execute {
      type = "collection.create",
      operation_id = "collection-create",
      expected_revision = 0,
      id = "collection-editor",
      title = "Editor",
    }
    test.equal(collection.code, "ok")
    test.equal(collection.revision, 1)

    local task = service:execute {
      type = "task.create",
      operation_id = "task-create",
      expected_revision = 1,
      id = "task-terminal",
      title = "Terminal integration",
      collection_id = "collection-editor",
    }
    test.equal(task.code, "ok")
    test.equal(task.revision, 2)

    local resource = service:execute {
      type = "resource.create",
      operation_id = "resource-create",
      expected_revision = 2,
      resource = {
        id = "terminal-build",
        kind = "terminal",
        title = "Build shell",
        collection_id = "collection-editor",
      },
    }
    test.equal(resource.code, "ok")
    test.equal(resource.revision, 3)
    test.equal(#seen, 3)
    test.equal(seen[1].type, "collection.created")
    test.equal(seen[2].type, "task.created")
    test.equal(seen[3].type, "resource.created")

    local snapshot = service:snapshot()
    test.equal(snapshot.workspace_id, "test-workspace")
    test.equal(snapshot.revision, 3)
    test.equal(#snapshot.collections, 1)
    test.equal(#snapshot.tasks, 1)
    test.equal(#snapshot.resources, 1)
    test.equal(#snapshot.terminals, 1)
    test.equal(snapshot.tasks[1].collection_id, "collection-editor")
  end)

  test.test("rejects stale revisions without mutating state", function()
    local created = service:execute {
      type = "collection.create",
      operation_id = "collection-create",
      expected_revision = 0,
      id = "collection-editor",
      title = "Editor",
    }
    test.equal(created.code, "ok")

    local result = service:execute {
      type = "task.create",
      operation_id = "task-stale",
      expected_revision = 0,
      id = "task-stale",
      title = "Stale task",
    }
    test.equal(result.code, "revision_conflict")
    test.equal(service:snapshot().revision, 1)
    test.equal(#service:snapshot().tasks, 0)
  end)

  test.test("replays an idempotent operation without incrementing revision", function()
    local command = {
      type = "collection.create",
      operation_id = "collection-idempotent",
      expected_revision = 0,
      id = "collection-editor",
      title = "Editor",
    }
    local first = service:execute(command)
    local second = service:execute(command)
    test.equal(first.code, "ok")
    test.same(second, first)
    test.equal(service:snapshot().revision, 1)
    test.equal(#service:snapshot().collections, 1)
  end)

  test.test("rejects reusing an operation ID for a different command", function()
    local first = service:execute {
      type = "collection.create",
      operation_id = "collection-idempotent",
      expected_revision = 0,
      id = "collection-editor",
      title = "Editor",
    }
    local conflict = service:execute {
      type = "collection.create",
      operation_id = "collection-idempotent",
      expected_revision = 1,
      id = "collection-editor",
      title = "Different editor",
    }
    test.equal(first.code, "ok")
    test.equal(conflict.code, "operation_conflict")
    test.equal(service:snapshot().revision, 1)
  end)

  test.test("supports terminal compatibility commands", function()
    local created = service:execute {
      type = "terminal.create",
      operation_id = "terminal-create",
      expected_revision = 0,
      id = "terminal-build",
      title = "Build shell",
      cols = 80,
      rows = 24,
      status = "starting",
    }
    test.equal(created.code, "ok")

    local updated = service:execute {
      type = "terminal.status",
      operation_id = "terminal-status",
      expected_revision = 1,
      terminal_id = "terminal-build",
      status = "running",
    }
    test.equal(updated.code, "ok")
    test.equal(service:snapshot().terminals[1].status, "running")
  end)

  test.test("enforces runtime lifecycle transitions", function()
    local starting = service:execute {
      type = "runtime.update",
      operation_id = "runtime-starting",
      expected_revision = 0,
      runtime = { id = "runtime-lifecycle", status = "starting" },
    }
    test.equal(starting.code, "ok")

    local running = service:execute {
      type = "runtime.update",
      operation_id = "runtime-running",
      expected_revision = 1,
      runtime = { id = "runtime-lifecycle", status = "running" },
    }
    test.equal(running.code, "ok")

    local stopping = service:execute {
      type = "runtime.update",
      operation_id = "runtime-stopping",
      expected_revision = 2,
      runtime = { id = "runtime-lifecycle", status = "stopping" },
    }
    test.equal(stopping.code, "ok")

    local stopped = service:execute {
      type = "runtime.update",
      operation_id = "runtime-stopped",
      expected_revision = 3,
      runtime = { id = "runtime-lifecycle", status = "stopped" },
    }
    test.equal(stopped.code, "ok")

    local invalid = service:execute {
      type = "runtime.update",
      operation_id = "runtime-invalid",
      expected_revision = 4,
      runtime = { id = "runtime-lifecycle", status = "exited" },
    }
    test.equal(invalid.code, "invalid_runtime_transition")
    test.equal(service:snapshot().runtimes[1].status, "stopped")
  end)

  test.test("deletes inactive runtime history without deleting its resource", function()
    local resource = service:execute {
      type = "resource.create",
      operation_id = "history-resource",
      expected_revision = 0,
      id = "history-resource",
      title = "History resource",
      kind = "terminal",
    }
    test.equal(resource.code, "ok")
    local runtime = service:execute {
      type = "runtime.update",
      operation_id = "history-runtime",
      expected_revision = 1,
      runtime = {
        id = "history-runtime",
        resource_id = "history-resource",
        status = "stopped",
        history_path = "/tmp/history-runtime.log",
        checkpoint_path = "/tmp/history-runtime.log.checkpoint",
      },
    }
    test.equal(runtime.code, "ok")
    local deleted = service:execute {
      type = "runtime.delete_history",
      operation_id = "history-delete",
      expected_revision = 2,
      runtime_id = "history-runtime",
    }
    test.equal(deleted.code, "ok")
    test.equal(#service:snapshot().runtimes, 0)
    test.equal(#service:snapshot().resources, 1)
  end)

  test.test("deleting a resource removes its inactive runtime records", function()
    test.equal(service:execute {
      type = "resource.create", operation_id = "remove-resource-create",
      expected_revision = 0, id = "remove-resource", title = "Remove resource",
      kind = "terminal",
    }.code, "ok")
    test.equal(service:execute {
      type = "runtime.update", operation_id = "remove-runtime-create",
      expected_revision = 1,
      runtime = { id = "remove-runtime", resource_id = "remove-resource", status = "stopped" },
    }.code, "ok")
    local deleted = service:execute {
      type = "resource.delete", operation_id = "remove-resource-delete",
      expected_revision = 2, resource_id = "remove-resource",
    }
    test.equal(deleted.code, "ok")
    test.equal(#service:snapshot().resources, 0)
    test.equal(#service:snapshot().runtimes, 0)
  end)

  test.test("rolls back an invalid command batch and defers events", function()
    local seen = {}
    service:subscribe(function(event) seen[#seen + 1] = event end)
    local result = service:execute_batch {
      {
        type = "collection.create",
        operation_id = "batch-collection",
        expected_revision = 0,
        id = "batch-collection",
        title = "Batch collection",
      },
      {
        type = "task.create",
        operation_id = "batch-invalid-task",
        expected_revision = 1,
        id = "batch-task",
        title = "",
      },
    }
    test.equal(result.code, "invalid_command")
    test.equal(service:snapshot().revision, 0)
    test.equal(#service:snapshot().collections, 0)
    test.equal(#seen, 0)
  end)
end)
