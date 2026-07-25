local common = require "core.common"
local Codec = require "plugins.workbench.service.codec"
local Migration = require "plugins.workbench.service.migration"

local sqlite_available, sqlite = pcall(require, "sqlite")

local Storage = {}
Storage.__index = Storage

local DEFAULT_EVENT_LIMIT = 4096

local function bool(value)
  return value == true or value == 1
end

local function parent_directory(path)
  return path:match("^(.+)[/\\][^/\\]+$")
end

local function decode(value, fallback)
  local result = Codec.decode(value)
  return result == nil and fallback or result
end

local function load_collections(db, workspace_id)
  local records = {}
  for _, row in ipairs(db:query([[
    SELECT id, parent_id, title, order_index, archived
      FROM collections WHERE workspace_id = ? ORDER BY order_index, id
  ]], { workspace_id })) do
    records[row.id] = {
      id = row.id,
      parent_id = row.parent_id,
      title = row.title,
      order = row.order_index,
      archived = bool(row.archived),
    }
  end
  return records
end

local function load_tasks(db, workspace_id)
  local records = {}
  for _, row in ipairs(db:query([[
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
  for _, row in ipairs(db:query([[
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

local function load_operations(db, workspace_id)
  local records = {}
  for _, row in ipairs(db:query([[
    SELECT operation_id, result FROM operations
      WHERE workspace_id = ? ORDER BY revision, operation_id
  ]], { workspace_id })) do
    records[row.operation_id] = decode(row.result, {})
  end
  return records
end

local function load_events(db, workspace_id, limit)
  local events = {}
  local rows = db:query([[
    SELECT payload FROM events WHERE workspace_id = ? ORDER BY event_id DESC
      LIMIT ?
  ]], { workspace_id, limit or DEFAULT_EVENT_LIMIT })
  for index = #rows, 1, -1 do
    local row = rows[index]
    local event = decode(row.payload)
    if event then events[#events + 1] = event end
  end
  return events
end

local function load_runtimes(db, workspace_id)
  local records = {}
  for _, row in ipairs(db:query([[
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
  for _, row in ipairs(db:query([[
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
  local ok, db = pcall(sqlite.open, path)
  if not ok then return nil, db end
  local success, message = pcall(Migration.apply, db)
  if not success then
    db:close()
    return nil, message
  end
  return setmetatable({
    path = path,
    db = db,
    event_limit = options.event_limit or DEFAULT_EVENT_LIMIT,
  }, Storage)
end

function Storage:load(workspace_id)
  local row = self.db:query([[
    SELECT id, name, revision, sequence, event_offset
      FROM workspaces WHERE id = ?
  ]], { workspace_id })[1]
  if not row then return nil end
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
    operations = load_operations(self.db, workspace_id),
    events = load_events(self.db, workspace_id, self.event_limit),
  }
end

local function save_collections(db, workspace_id, records)
  db:execute("DELETE FROM collections WHERE workspace_id = ?", { workspace_id })
  for _, record in pairs(records) do
    db:execute([[
      INSERT INTO collections(id, workspace_id, parent_id, title, order_index, archived)
      VALUES (?, ?, ?, ?, ?, ?)
    ]], {
      record.id, workspace_id, record.parent_id, record.title, record.order or 0,
      record.archived and 1 or 0
    })
  end
end

local function save_tasks(db, workspace_id, records)
  db:execute("DELETE FROM tasks WHERE workspace_id = ?", { workspace_id })
  for _, record in pairs(records) do
    db:execute([[
      INSERT INTO tasks(id, workspace_id, collection_id, title, status, order_index, archived)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    ]], {
      record.id, workspace_id, record.collection_id, record.title, record.status,
      record.order or 0, record.archived and 1 or 0
    })
  end
end

local function save_resources(db, workspace_id, records)
  db:execute("DELETE FROM resources WHERE workspace_id = ?", { workspace_id })
  for _, record in pairs(records) do
    db:execute([[
      INSERT INTO resources(
        id, workspace_id, kind, provider, title, collection_id, config, status,
        cols, rows, order_index, archived
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
      record.id, workspace_id, record.kind, record.provider, record.title,
      record.collection_id, Codec.encode(record.config or {}), record.status,
      record.cols or 80, record.rows or 24, record.order or 0,
      record.archived and 1 or 0
    })
  end
end

local function save_runtimes(db, workspace_id, records)
  db:execute("DELETE FROM runtimes WHERE workspace_id = ?", { workspace_id })
  for _, record in pairs(records) do
    db:execute([[
      INSERT INTO runtimes(
        id, workspace_id, resource_id, status, pid, started_at, ended_at,
        output_bytes, output_offset, history_path, metadata
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
      record.id, workspace_id, record.resource_id, record.status, record.pid,
      record.started_at, record.ended_at, record.output_bytes or 0,
      record.output_offset or 0, record.history_path,
      Codec.encode(record.metadata or {}),
    })
  end
end

local function save_provider_metadata(db, workspace_id, records)
  db:execute("DELETE FROM provider_metadata WHERE workspace_id = ?", { workspace_id })
  for _, record in pairs(records) do
    db:execute([[
      INSERT INTO provider_metadata(workspace_id, provider_id, metadata)
      VALUES (?, ?, ?)
    ]], {
      workspace_id, record.provider_id, Codec.encode(record.metadata or {})
    })
  end
end

function Storage:commit(service, operation_id, result, events)
  local ok, message = pcall(function()
    self.db:execute("BEGIN")
    self.db:execute([[
      INSERT INTO workspaces(id, name, revision, sequence, event_offset)
        VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        revision = excluded.revision,
        sequence = excluded.sequence,
        event_offset = excluded.event_offset
    ]], {
      service.workspace_id, service.name, service.revision, service.sequence,
      service.event_offset or 0,
    })
    save_collections(self.db, service.workspace_id, service.collections)
    save_tasks(self.db, service.workspace_id, service.tasks)
    save_resources(self.db, service.workspace_id, service.resources)
    save_runtimes(self.db, service.workspace_id, service.runtimes)
    save_provider_metadata(self.db, service.workspace_id, service.provider_metadata)
    self.db:execute([[
      INSERT OR REPLACE INTO operations(operation_id, workspace_id, revision, result)
      VALUES (?, ?, ?, ?)
    ]], {
      operation_id, service.workspace_id, service.revision, Codec.encode(result)
    })
    for _, event in ipairs(events or {}) do
      self.db:execute([[
        INSERT INTO events(workspace_id, revision, payload) VALUES (?, ?, ?)
      ]], { service.workspace_id, service.revision, Codec.encode(event) })
    end
    local event_limit = service.event_limit or self.event_limit
    self.db:execute([[
      DELETE FROM events
       WHERE workspace_id = ?
         AND event_id NOT IN (
           SELECT event_id FROM events
            WHERE workspace_id = ? ORDER BY event_id DESC LIMIT ?
         )
    ]], { service.workspace_id, service.workspace_id, event_limit })
    self.db:execute("COMMIT")
  end)
  if not ok then
    pcall(function() self.db:execute("ROLLBACK") end)
    return false, message
  end
  return true
end

function Storage:close()
  if self.db then
    self.db:close()
    self.db = nil
  end
end

return Storage
