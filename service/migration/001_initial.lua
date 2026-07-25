return {
  version = 1,

  up = function(db)
    db:execute [[
      CREATE TABLE IF NOT EXISTS workspaces (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 0,
        sequence INTEGER NOT NULL DEFAULT 0
      )
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS collections (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        parent_id TEXT,
        title TEXT NOT NULL,
        order_index INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        collection_id TEXT,
        title TEXT NOT NULL,
        status TEXT,
        order_index INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS resources (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        provider TEXT,
        title TEXT NOT NULL,
        collection_id TEXT,
        config TEXT NOT NULL DEFAULT '{}',
        status TEXT,
        cols INTEGER NOT NULL DEFAULT 80,
        rows INTEGER NOT NULL DEFAULT 24,
        order_index INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS operations (
        operation_id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        result TEXT NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        workspace_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        payload TEXT NOT NULL,
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute "CREATE INDEX IF NOT EXISTS events_workspace_id ON events(workspace_id, event_id)"
    db:execute "CREATE INDEX IF NOT EXISTS operations_workspace_id ON operations(workspace_id)"
  end
}
