local test = require "core.test"
local sqlite = require "sqlite"
local Service = require "plugins.workbench.service"
local Storage = require "plugins.workbench.service.storage"

local workspace_sequence = 0

local function new_workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "persistence-test-" .. tostring(workspace_sequence)
end

test.describe("Workbench SQLite persistence", function()
  test.test("uses structured errors, explicit transactions, and MessagePack blobs", function()
    local path = os.tmpname()
    os.remove(path)
    local store = assert(Storage.new(path))

    local result, error_result = store.db:query("SELECT * FROM missing_workbench_table")
    test.equal(result, nil)
    test.equal(type(error_result), "table")
    test.equal(error_result.code, 1)
    test.equal(type(error_result.message), "string")

    local blob = sqlite.blob("\0\xff")
    local rows = assert(store.db:query("SELECT typeof(?) AS kind, ? AS value", { blob, blob }))
    test.equal(rows[1].kind, "blob")
    test.equal(rows[1].value, "\0\xff")

    test.equal(store.db:begin("immediate"), true)
    test.equal(store.db:in_transaction(), true)
    test.equal(store.db:rollback(), true)
    test.equal(store.db:in_transaction(), false)

    store:close()
    os.remove(path)
  end)

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
    local operation_row = assert(store.db:query([[
      SELECT typeof(command_digest) AS digest_type FROM operations
       WHERE workspace_id = ? AND operation_id = ?
    ]], { workspace_id, "persist-resource" }))[1]
    test.equal(operation_row.digest_type, "blob")
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
        provider = "builtin.shell",
        external_session_id = "shell-session-1",
        capabilities = { replay = true },
        execution_policy = {
          approval = "prompt",
          sandbox = "workspace",
          permissions = { network = "prompt" },
        },
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
    test.equal(snapshot.runtimes[1].provider, "builtin.shell")
    test.equal(snapshot.runtimes[1].external_session_id, "shell-session-1")
    test.ok(snapshot.runtimes[1].capabilities.replay)
    test.equal(snapshot.runtimes[1].execution_policy.approval, "prompt")
    test.equal(snapshot.runtimes[1].execution_policy.permissions.network, "prompt")
    test.equal(snapshot.provider_metadata[1].metadata.version, 1)

    local replayed = reopened:execute {
      type = "resource.create",
      operation_id = "persist-resource",
      expected_revision = 5,
      resource = {
        id = "terminal-persisted",
        kind = "terminal",
        title = "Persisted shell",
        config = { cwd = "/tmp", shell = "/bin/sh" },
        status = "starting",
      },
    }
    test.same(replayed, resource)
    local conflict = reopened:execute {
      type = "resource.create",
      operation_id = "persist-resource",
      expected_revision = 5,
      resource = {
        id = "terminal-persisted",
        kind = "terminal",
        title = "Different shell",
      },
    }
    test.equal(conflict.code, "operation_conflict")
    test.equal(reopened:snapshot().revision, 5)
    reopened:close()
    os.remove(path)
  end)

  test.test("rejects a stale second service at the database CAS", function()
    local path = os.tmpname()
    os.remove(path)
    local workspace_id = new_workspace_id()
    local first_store = assert(Storage.new(path))
    local second_store = assert(Storage.new(path))
    local first = Service.new { workspace_id = workspace_id, store = first_store }
    local second = Service.new { workspace_id = workspace_id, store = second_store }

    test.equal(first:execute {
      type = "collection.create",
      operation_id = "cas-first",
      expected_revision = 0,
      id = "cas-collection",
      title = "First writer",
    }.code, "ok")
    local stale = second:execute {
      type = "collection.create",
      operation_id = "cas-second",
      expected_revision = 0,
      id = "cas-second-collection",
      title = "Stale writer",
    }
    test.equal(stale.code, "revision_conflict")
    test.equal(second:snapshot().revision, 0)
    test.equal(#second:snapshot().collections, 0)

    first:close()
    second:close()
    os.remove(path)
  end)

  test.test("persists only records in the command write-set", function()
    local path = os.tmpname()
    os.remove(path)
    local workspace_id = new_workspace_id()
    local store = assert(Storage.new(path))
    local service = Service.new { workspace_id = workspace_id, store = store }

    test.equal(service:execute {
      type = "collection.create",
      operation_id = "write-set-first",
      expected_revision = 0,
      id = "write-set-first",
      title = "First",
    }.code, "ok")
    local first_row = assert(store.db:query([[
      SELECT rowid FROM collections WHERE workspace_id = ? AND id = ?
    ]], { workspace_id, "write-set-first" }))[1].rowid

    test.equal(service:execute {
      type = "collection.create",
      operation_id = "write-set-second",
      expected_revision = 1,
      id = "write-set-second",
      title = "Second",
    }.code, "ok")
    local unchanged_row = assert(store.db:query([[
      SELECT rowid FROM collections WHERE workspace_id = ? AND id = ?
    ]], { workspace_id, "write-set-first" }))[1].rowid
    test.equal(unchanged_row, first_row)

    local deleted = service:execute {
      type = "collection.delete",
      operation_id = "write-set-delete",
      expected_revision = 2,
      id = "write-set-second",
    }
    test.equal(deleted.code, "ok")
    test.equal(assert(store.db:query([[
      SELECT COUNT(*) AS count FROM collections
       WHERE workspace_id = ? AND id = ?
    ]], { workspace_id, "write-set-second" }))[1].count, 0)
    test.equal(assert(store.db:query([[
      SELECT rowid FROM collections WHERE workspace_id = ? AND id = ?
    ]], { workspace_id, "write-set-first" }))[1].rowid, first_row)

    service:close()
    os.remove(path)
  end)

  test.test("bounds persisted operation idempotency records", function()
    local path = os.tmpname()
    os.remove(path)
    local workspace_id = new_workspace_id()
    local store = assert(Storage.new(path, { operation_limit = 2 }))
    local service = Service.new {
      workspace_id = workspace_id,
      store = store,
      operation_limit = 2,
    }
    for index = 1, 3 do
      local result = service:execute {
        type = "workspace.rename",
        operation_id = "operation-limit-" .. tostring(index),
        expected_revision = index - 1,
        name = "Workspace " .. tostring(index),
      }
      test.equal(result.code, "ok")
    end
    local rows = assert(store.db:query([[
      SELECT operation_id FROM operations WHERE workspace_id = ?
      ORDER BY revision
    ]], { workspace_id }))
    test.equal(#rows, 2)
    test.equal(rows[1].operation_id, "operation-limit-2")
    test.equal(rows[2].operation_id, "operation-limit-3")
    service:close()
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
    test.equal(service:snapshot().event_cursor, 3)
    local events, error_result = service:get_events(0)
    test.equal(events, nil)
    test.equal(error_result.code, "snapshot_required")
    test.equal(error_result.oldest_event_sequence, 2)
    events = assert(service:get_events(1))
    test.equal(#events, 2)
    test.equal(events[1].event_sequence, 2)
    test.equal(events[2].event_sequence, 3)
    service:close()

    local reopened = Service.new {
      workspace_id = service.workspace_id,
      store = assert(Storage.new(path, { event_limit = 2 })),
      event_limit = 2,
    }
    test.equal(reopened:snapshot().event_cursor, 3)
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

  test.test("rolls back every persistence commit stage", function()
    local stages = { "write_set", "operation_insert", "event_insert", "revision_cas" }
    for index, stage in ipairs(stages) do
      local path = os.tmpname()
      os.remove(path)
      local workspace_id = "fault-stage-" .. stage .. "-" .. tostring(index)
      local store = assert(Storage.new(path, { fault_stage = stage }))
      local seen = {}
      local service = Service.new { workspace_id = workspace_id, store = store }
      service:subscribe(function(event) seen[#seen + 1] = event end)
      local command = {
        type = "collection.create",
        operation_id = "fault-stage-operation-" .. stage,
        expected_revision = 0,
        id = "fault-stage-collection-" .. stage,
        title = "Fault stage",
      }
      local failed = service:execute(command)
      test.equal(failed.code, "fault_injected")
      test.equal(service:snapshot().revision, 0)
      test.equal(#service:snapshot().collections, 0)
      test.equal(#seen, 0)

      store.fault_stage = nil
      local committed = service:execute(command)
      test.equal(committed.code, "ok")
      test.equal(committed.revision, 1)
      test.equal(#seen, 1)
      service:close()

      local reopened = Service.new {
        workspace_id = workspace_id,
        store = assert(Storage.new(path)),
      }
      test.equal(reopened:snapshot().revision, 1)
      test.equal(#reopened:snapshot().collections, 1)
      reopened:close()
      os.remove(path)
    end
  end)

  test.test("commits and rolls back command batches atomically", function()
    local path = os.tmpname()
    os.remove(path)
    local workspace_id = new_workspace_id()
    local service = Service.new {
      workspace_id = workspace_id,
      store = assert(Storage.new(path)),
    }
    local committed = service:execute_batch {
      {
        type = "collection.create",
        operation_id = "batch-persisted-collection",
        expected_revision = 0,
        id = "batch-persisted-collection",
        title = "Batch collection",
      },
      {
        type = "task.create",
        operation_id = "batch-persisted-task",
        expected_revision = 1,
        id = "batch-persisted-task",
        title = "Batch task",
        collection_id = "batch-persisted-collection",
      },
    }
    test.equal(committed.code, "ok")
    test.equal(service:snapshot().revision, 2)
    local rejected = service:execute_batch {
      {
        type = "collection.create",
        operation_id = "batch-rolled-back-collection",
        expected_revision = 2,
        id = "batch-rolled-back-collection",
        title = "Should roll back",
      },
      {
        type = "task.create",
        operation_id = "batch-rolled-back-task",
        expected_revision = 3,
        id = "batch-rolled-back-task",
        title = "",
      },
    }
    test.equal(rejected.code, "invalid_command")
    test.equal(service:snapshot().revision, 2)
    service:close()

    local reopened = Service.new {
      workspace_id = workspace_id,
      store = assert(Storage.new(path)),
    }
    test.equal(reopened:snapshot().revision, 2)
    test.equal(#reopened:snapshot().collections, 1)
    test.equal(#reopened:snapshot().tasks, 1)
    reopened:close()
    os.remove(path)
  end)
end)
