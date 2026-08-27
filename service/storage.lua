local common = require "core.common"
local MessagePack = require "plugins.workbench.service.msgpack"
local Migration = require "plugins.workbench.service.migration"

local sqlite_available, sqlite = pcall(require, "sqlite")

local Storage = {}
Storage.__index = Storage

local DEFAULT_EVENT_LIMIT = 4096
local DEFAULT_OPERATION_LIMIT = 4096

local function bool(value)
  return value == true or value == 1
end

local function parent_directory(path)
  return path:match("^(.+)[/\\][^/\\]+$")
end

local function database_error(result)
  if type(result) == "table" then
    return string.format("SQLite error %s (%s/%s): %s",
      tostring(result.name or "error"), tostring(result.code or "?"),
      tostring(result.extended_code or "?"), tostring(result.message or "unknown error"))
  end
  return tostring(result)
end

local function execute(db, sql, parameters)
  local ok, result = db:execute(sql, parameters)
  if not ok then error(database_error(result)) end
  return ok
end

local function query(db, sql, parameters)
  local rows, result = db:query(sql, parameters)
  if not rows then error(database_error(result)) end
  return rows
end

local function transaction(db, method, ...)
  local ok, result = db[method](db, ...)
  if not ok then error(database_error(result)) end
  return ok
end

local function encode(value)
  return sqlite.blob(MessagePack.encode(value))
end

local function decode(value, fallback)
  if value == nil then return fallback end
  local ok, result = pcall(MessagePack.decode, value)
  if not ok then error("invalid Workbench MessagePack value: " .. tostring(result)) end
  return result == nil and fallback or result
end

local function load_collections(db, workspace_id)
  local records = {}
  for _, row in ipairs(query(db, [[
    SELECT id, parent_id, title, order_index, archived
      FROM collections WHERE workspace_id = ? ORDER BY order_index, id
  ]], { workspace_id })) do
    records[row.id] = {
      id = row.id,
      parent_id = row.parent_id or "root",
      title = row.title,
      order = row.order_index,
      archived = bool(row.archived),
    }
  end
  return records
end

local function load_tasks(db, workspace_id)
  local records = {}
  for _, row in ipairs(query(db, [[
    SELECT id, collection_id, title, status, order_index, archived
      FROM tasks WHERE workspace_id = ? ORDER BY order_index, id
  ]], { workspace_id })) do
    records[row.id] = {
      id = row.id,
      collection_id = row.collection_id,
      title = row.title,
      status = row.status,
      order = row.order_index,
      archived = bool(row.archived),
    }
  end
  return records
end

local function load_resources(db, workspace_id)
  local records = {}
  for _, row in ipairs(query(db, [[
    SELECT id, kind, provider, title, collection_id, config, status,
           cols, rows, order_index, archived
      FROM resources WHERE workspace_id = ? ORDER BY order_index, id
  ]], { workspace_id })) do
    records[row.id] = {
      id = row.id,
      kind = row.kind,
      provider = row.provider,
      title = row.title,
      collection_id = row.collection_id,
      config = decode(row.config, {}),
      status = row.status,
      cols = row.cols,
      rows = row.rows,
      order = row.order_index,
      archived = bool(row.archived),
    }
  end
  return records
end

local function load_operations(db, workspace_id, limit)
  local records = {}
  local digests = {}
  for _, row in ipairs(query(db, [[
    SELECT operation_id, result, command_digest FROM operations
      WHERE workspace_id = ? ORDER BY revision DESC, operation_id DESC LIMIT ?
  ]], { workspace_id, limit or DEFAULT_OPERATION_LIMIT })) do
    records[row.operation_id] = decode(row.result, {})
    digests[row.operation_id] = row.command_digest
  end
  return records, digests
end

local function load_events(db, workspace_id, limit)
  local events = {}
  local rows = query(db, [[
    SELECT payload FROM events WHERE workspace_id = ? ORDER BY event_id DESC
      LIMIT ?
  ]], { workspace_id, limit or DEFAULT_EVENT_LIMIT })
  for index = #rows, 1, -1 do
    local event = decode(rows[index].payload)
    if event then events[#events + 1] = event end
  end
  return events
end

local function load_runtimes(db, workspace_id)
  local records = {}
  for _, row in ipairs(query(db, [[
    SELECT id, resource_id, status, pid, started_at, ended_at,
           output_bytes, output_offset, history_path, metadata
      FROM runtimes WHERE workspace_id = ? ORDER BY id
  ]], { workspace_id })) do
    records[row.id] = {
      id = row.id,
      resource_id = row.resource_id,
      status = row.status,
      pid = row.pid,
      started_at = row.started_at,
      ended_at = row.ended_at,
      output_bytes = row.output_bytes or 0,
      output_offset = row.output_offset or 0,
      history_path = row.history_path,
      metadata = decode(row.metadata, {}),
    }
  end
  return records
end

local function load_provider_metadata(db, workspace_id)
  local records = {}
  for _, row in ipairs(query(db, [[
    SELECT provider_id, metadata FROM provider_metadata
      WHERE workspace_id = ? ORDER BY provider_id
  ]], { workspace_id })) do
    records[row.provider_id] = {
      provider_id = row.provider_id,
      metadata = decode(row.metadata, {}),
    }
  end
  return records
end

function Storage.new(path, options)
  options = options or {}
  if not sqlite_available then
    return nil, "SQLite support is unavailable: " .. tostring(sqlite)
  end
  local directory = parent_directory(path)
  if directory and not system.get_file_info(directory) then
    local ok, message = common.mkdirp(directory)
    if not ok then return nil, message end
  end
  local db, result = sqlite.open(path)
  if not db then return nil, database_error(result) end
  local success, message = pcall(Migration.apply, db)
  if not success then
    db:close()
    return nil, message
  end
  return setmetatable({
    path = path,
    db = db,
    event_limit = options.event_limit or DEFAULT_EVENT_LIMIT,
    operation_limit = options.operation_limit or DEFAULT_OPERATION_LIMIT,
  }, Storage)
end

function Storage:load(workspace_id)
  local row = query(self.db, [[
    SELECT id, name, revision, sequence, event_offset
      FROM workspaces WHERE id = ?
  ]], { workspace_id })[1]
  if not row then return nil end
  local operations, operation_digests = load_operations(
    self.db, workspace_id, self.operation_limit)
  return {
    workspace_id = row.id,
    name = row.name,
    revision = row.revision,
    sequence = row.sequence,
    event_offset = row.event_offset or 0,
    collections = load_collections(self.db, workspace_id),
    tasks = load_tasks(self.db, workspace_id),
    resources = load_resources(self.db, workspace_id),
    runtimes = load_runtimes(self.db, workspace_id),
    provider_metadata = load_provider_metadata(self.db, workspace_id),
    operations = operations,
    operation_digests = operation_digests,
    events = load_events(self.db, workspace_id, self.event_limit),
  }
end

local function apply_collections(db, workspace_id, changes, mode)
  if mode ~= "delete" then for _, record in ipairs(changes.upsert) do
    execute(db, [[
      INSERT INTO collections(workspace_id, id, parent_id, title, order_index, archived)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(workspace_id, id) DO UPDATE SET
        parent_id = excluded.parent_id,
        title = excluded.title,
        order_index = excluded.order_index,
        archived = excluded.archived
    ]], {
      workspace_id, record.id, record.parent_id ~= "root" and record.parent_id or nil,
      record.title, record.order or 0, record.archived and 1 or 0
    })
  end end
  if mode ~= "upsert" then for _, id in ipairs(changes.delete) do
    execute(db, "DELETE FROM collections WHERE workspace_id = ? AND id = ?",
      { workspace_id, id })
  end end
end

local function apply_tasks(db, workspace_id, changes, mode)
  if mode ~= "delete" then for _, record in ipairs(changes.upsert) do
    execute(db, [[
      INSERT INTO tasks(workspace_id, id, collection_id, title, status, order_index, archived)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(workspace_id, id) DO UPDATE SET
        collection_id = excluded.collection_id,
        title = excluded.title,
        status = excluded.status,
        order_index = excluded.order_index,
        archived = excluded.archived
    ]], {
      workspace_id, record.id, record.collection_id, record.title, record.status,
      record.order or 0, record.archived and 1 or 0
    })
  end end
  if mode ~= "upsert" then for _, id in ipairs(changes.delete) do
    execute(db, "DELETE FROM tasks WHERE workspace_id = ? AND id = ?",
      { workspace_id, id })
  end end
end

local function apply_resources(db, workspace_id, changes, mode)
  if mode ~= "delete" then for _, record in ipairs(changes.upsert) do
    execute(db, [[
      INSERT INTO resources(
        workspace_id, id, kind, provider, title, collection_id, config, status,
        cols, rows, order_index, archived
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(workspace_id, id) DO UPDATE SET
        kind = excluded.kind,
        provider = excluded.provider,
        title = excluded.title,
        collection_id = excluded.collection_id,
        config = excluded.config,
        status = excluded.status,
        cols = excluded.cols,
        rows = excluded.rows,
        order_index = excluded.order_index,
        archived = excluded.archived
    ]], {
      workspace_id, record.id, record.kind, record.provider, record.title,
      record.collection_id, encode(record.config or {}), record.status or "stopped",
      record.cols or 80, record.rows or 24, record.order or 0,
      record.archived and 1 or 0
    })
  end end
  if mode ~= "upsert" then for _, id in ipairs(changes.delete) do
    execute(db, "DELETE FROM resources WHERE workspace_id = ? AND id = ?",
      { workspace_id, id })
  end end
end

local function apply_runtimes(db, workspace_id, changes, mode)
  if mode ~= "delete" then for _, record in ipairs(changes.upsert) do
    execute(db, [[
      INSERT INTO runtimes(
        workspace_id, id, resource_id, status, pid, started_at, ended_at,
        output_bytes, output_offset, history_path, metadata
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(workspace_id, id) DO UPDATE SET
        resource_id = excluded.resource_id,
        status = excluded.status,
        pid = excluded.pid,
        started_at = excluded.started_at,
        ended_at = excluded.ended_at,
        output_bytes = excluded.output_bytes,
        output_offset = excluded.output_offset,
        history_path = excluded.history_path,
        metadata = excluded.metadata
    ]], {
      workspace_id, record.id, record.resource_id, record.status or "stopped", record.pid,
      record.started_at, record.ended_at, record.output_bytes or 0,
      record.output_offset or 0, record.history_path, encode(record.metadata or {}),
    })
  end end
  if mode ~= "upsert" then for _, id in ipairs(changes.delete) do
    execute(db, "DELETE FROM runtimes WHERE workspace_id = ? AND id = ?",
      { workspace_id, id })
  end end
end

local function apply_provider_metadata(db, workspace_id, changes, mode)
  if mode ~= "delete" then for _, record in ipairs(changes.upsert) do
    execute(db, [[
      INSERT INTO provider_metadata(workspace_id, provider_id, metadata)
      VALUES (?, ?, ?)
      ON CONFLICT(workspace_id, provider_id) DO UPDATE SET
        metadata = excluded.metadata,
        updated_at = CURRENT_TIMESTAMP
    ]], {
      workspace_id, record.provider_id, encode(record.metadata or {})
    })
  end end
  if mode ~= "upsert" then for _, id in ipairs(changes.delete) do
    execute(db, [[
      DELETE FROM provider_metadata WHERE workspace_id = ? AND provider_id = ?
    ]], { workspace_id, id })
  end end
end

function Storage:commit(service, operation_id, result, events, command_digest,
    expected_previous_revision, write_set)
  local own_transaction = not self.in_transaction
  local ok, message = pcall(function()
    if own_transaction then transaction(self.db, "begin", "immediate") end

    local expected = expected_previous_revision
    if expected == nil then expected = service.revision - 1 end
    local workspace = query(self.db, [[
      SELECT revision FROM workspaces WHERE id = ?
    ]], { service.workspace_id })[1]
    local actual = workspace and workspace.revision or 0
    if actual ~= expected then
      error {
        code = "revision_conflict",
        message = "database revision " .. tostring(actual)
          .. " does not match expected revision " .. tostring(expected),
        expected_revision = expected,
        actual_revision = actual,
      }
    end
    if not workspace then
      execute(self.db, [[
        INSERT INTO workspaces(id, name, revision, sequence, event_offset)
        VALUES (?, ?, 0, 0, 0)
      ]], { service.workspace_id, service.name })
    end

    local existing_operation = query(self.db, [[
      SELECT command_digest FROM operations
       WHERE workspace_id = ? AND operation_id = ?
    ]], { service.workspace_id, operation_id })[1]
    if existing_operation then
      if existing_operation.command_digest ~= command_digest then
        error {
          code = "operation_conflict",
          message = "operation_id is already bound to a different command",
        }
      end
      error {
        code = "operation_exists",
        message = "operation_id is already committed",
      }
    end

    if not write_set then error "database write-set is required" end
    -- Apply all upserts before deletes so deferred relationships can be
    -- repaired atomically when a parent or resource is removed.
    apply_collections(self.db, service.workspace_id, write_set.collections, "upsert")
    apply_tasks(self.db, service.workspace_id, write_set.tasks, "upsert")
    apply_resources(self.db, service.workspace_id, write_set.resources, "upsert")
    apply_runtimes(self.db, service.workspace_id, write_set.runtimes, "upsert")
    apply_provider_metadata(self.db, service.workspace_id, write_set.provider_metadata, "upsert")
    apply_runtimes(self.db, service.workspace_id, write_set.runtimes, "delete")
    apply_resources(self.db, service.workspace_id, write_set.resources, "delete")
    apply_tasks(self.db, service.workspace_id, write_set.tasks, "delete")
    apply_collections(self.db, service.workspace_id, write_set.collections, "delete")
    apply_provider_metadata(self.db, service.workspace_id, write_set.provider_metadata, "delete")
    execute(self.db, [[
      INSERT INTO operations(
        workspace_id, operation_id, revision, command_digest, result
      ) VALUES (?, ?, ?, ?, ?)
    ]], {
      service.workspace_id, operation_id, service.revision,
      sqlite.blob(command_digest), encode(result)
    })
    for _, event in ipairs(events or {}) do
      execute(self.db, [[
        INSERT INTO events(workspace_id, revision, payload) VALUES (?, ?, ?)
      ]], { service.workspace_id, service.revision, encode(event) })
    end
    local event_limit = service.event_limit or self.event_limit
    execute(self.db, [[
      DELETE FROM events
       WHERE workspace_id = ?
         AND event_id NOT IN (
           SELECT event_id FROM events
            WHERE workspace_id = ? ORDER BY event_id DESC LIMIT ?
         )
    ]], { service.workspace_id, service.workspace_id, event_limit })
    local operation_limit = service.operation_limit or self.operation_limit
    execute(self.db, [[
      DELETE FROM operations
       WHERE workspace_id = ?
         AND operation_id NOT IN (
           SELECT operation_id FROM operations
            WHERE workspace_id = ?
            ORDER BY revision DESC, operation_id DESC LIMIT ?
         )
    ]], { service.workspace_id, service.workspace_id, operation_limit })
    execute(self.db, [[
      UPDATE workspaces
         SET name = ?, revision = ?, sequence = ?, event_offset = ?
       WHERE id = ? AND revision = ?
    ]], {
      service.name, service.revision, service.sequence, service.event_offset or 0,
      service.workspace_id, expected,
    })
    if self.db:changes() ~= 1 then
      error {
        code = "revision_conflict",
        message = "database revision compare-and-swap failed",
        expected_revision = expected,
      }
    end
    if own_transaction then transaction(self.db, "commit") end
  end)
  if not ok then
    if own_transaction then pcall(function() transaction(self.db, "rollback") end) end
    return false, message
  end
  return true
end

function Storage:begin_transaction()
  if self.in_transaction then return false, "storage transaction is already active" end
  local ok, message = pcall(function() transaction(self.db, "begin", "immediate") end)
  if not ok then return false, message end
  self.in_transaction = true
  return true
end

function Storage:end_transaction(commit)
  if not self.in_transaction then return true end
  local ok, message = pcall(function()
    transaction(self.db, commit and "commit" or "rollback")
  end)
  self.in_transaction = false
  if not ok then return false, message end
  return true
end

function Storage:close()
  if self.db then
    if self.in_transaction then self:end_transaction(false) end
    self.db:close()
    self.db = nil
  end
end

return Storage
