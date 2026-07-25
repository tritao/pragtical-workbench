return {
  version = 2,

  up = function(db)
    db:execute [[
      ALTER TABLE workspaces
        ADD COLUMN event_offset INTEGER NOT NULL DEFAULT 0
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS runtimes (
        id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL,
        resource_id TEXT,
        status TEXT,
        pid INTEGER,
        started_at TEXT,
        ended_at TEXT,
        output_bytes INTEGER NOT NULL DEFAULT 0,
        output_offset INTEGER NOT NULL DEFAULT 0,
        history_path TEXT,
        metadata TEXT NOT NULL DEFAULT '{}',
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute [[
      CREATE TABLE IF NOT EXISTS provider_metadata (
        workspace_id TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        metadata TEXT NOT NULL DEFAULT '{}',
        updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (workspace_id, provider_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
      )
    ]]
    db:execute [[
      CREATE INDEX IF NOT EXISTS runtimes_workspace_id
        ON runtimes(workspace_id, id)
    ]]
  end,
}
