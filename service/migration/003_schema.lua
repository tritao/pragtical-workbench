local function execute(db, sql)
  local ok, result = db:execute(sql)
  if not ok then
    local message = type(result) == "table" and result.message or result
    error("SQLite schema error: " .. tostring(message))
  end
end

return {
  version = 3,

  up = function(db)
    execute(db, [[
      CREATE TABLE workspaces (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL CHECK(length(name) > 0),
        revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
        sequence INTEGER NOT NULL DEFAULT 0 CHECK(sequence >= 0),
        event_offset INTEGER NOT NULL DEFAULT 0 CHECK(event_offset >= 0)
      )
    ]])
    execute(db, [[
      CREATE TABLE collections (
        workspace_id TEXT NOT NULL,
        id TEXT NOT NULL,
        parent_id TEXT,
        title TEXT NOT NULL CHECK(length(title) > 0),
        order_index INTEGER NOT NULL DEFAULT 0 CHECK(order_index >= 0),
        archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
        PRIMARY KEY (workspace_id, id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED,
        FOREIGN KEY (workspace_id, parent_id)
          REFERENCES collections(workspace_id, id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE TABLE tasks (
        workspace_id TEXT NOT NULL,
        id TEXT NOT NULL,
        collection_id TEXT,
        title TEXT NOT NULL CHECK(length(title) > 0),
        status TEXT NOT NULL DEFAULT 'active' CHECK(length(status) > 0),
        order_index INTEGER NOT NULL DEFAULT 0 CHECK(order_index >= 0),
        archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
        PRIMARY KEY (workspace_id, id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED,
        FOREIGN KEY (workspace_id, collection_id)
          REFERENCES collections(workspace_id, id) ON DELETE SET NULL
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE TABLE resources (
        workspace_id TEXT NOT NULL,
        id TEXT NOT NULL,
        kind TEXT NOT NULL CHECK(length(kind) > 0),
        provider TEXT,
        title TEXT NOT NULL CHECK(length(title) > 0),
        collection_id TEXT,
        config BLOB NOT NULL,
        status TEXT NOT NULL DEFAULT 'stopped'
          CHECK(status IN ('starting', 'running', 'stopping', 'stopped',
                           'exited', 'interrupted', 'recovering', 'failed', 'closed')),
        cols INTEGER NOT NULL DEFAULT 80 CHECK(cols BETWEEN 1 AND 1000),
        rows INTEGER NOT NULL DEFAULT 24 CHECK(rows BETWEEN 1 AND 1000),
        order_index INTEGER NOT NULL DEFAULT 0 CHECK(order_index >= 0),
        archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
        PRIMARY KEY (workspace_id, id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED,
        FOREIGN KEY (workspace_id, collection_id)
          REFERENCES collections(workspace_id, id) ON DELETE SET NULL
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE TABLE runtimes (
        workspace_id TEXT NOT NULL,
        id TEXT NOT NULL,
        resource_id TEXT,
        status TEXT NOT NULL DEFAULT 'stopped'
          CHECK(status IN ('starting', 'running', 'stopping', 'stopped',
                           'exited', 'interrupted', 'recovering', 'failed', 'closed')),
        pid INTEGER CHECK(pid IS NULL OR pid > 0),
        started_at TEXT,
        ended_at TEXT,
        output_bytes INTEGER NOT NULL DEFAULT 0 CHECK(output_bytes >= 0),
        output_offset INTEGER NOT NULL DEFAULT 0 CHECK(output_offset >= 0),
        history_path TEXT,
        metadata BLOB NOT NULL,
        PRIMARY KEY (workspace_id, id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED,
        FOREIGN KEY (workspace_id, resource_id)
          REFERENCES resources(workspace_id, id) ON DELETE SET NULL
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE TABLE provider_metadata (
        workspace_id TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        metadata BLOB NOT NULL,
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (workspace_id, provider_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE TABLE operations (
        workspace_id TEXT NOT NULL,
        operation_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision >= 0),
        result BLOB NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (workspace_id, operation_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE TABLE events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision >= 0),
        payload BLOB NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, [[
      CREATE INDEX events_workspace_id ON events(workspace_id, event_id)
    ]])
    execute(db, [[
      CREATE INDEX operations_workspace_id ON operations(workspace_id, revision)
    ]])
    execute(db, [[
      CREATE INDEX runtimes_workspace_id ON runtimes(workspace_id, id)
    ]])
  end,
}
