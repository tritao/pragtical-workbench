local function execute(db, sql, parameters)
  local ok, result = db:execute(sql, parameters)
  if not ok then
    local message = type(result) == "table" and result.message or result
    error("SQLite schema error: " .. tostring(message))
  end
end

return {
  version = 4,

  up = function(db)
    local rows, result = db:query("SELECT COUNT(*) AS count FROM operations")
    if not rows then
      error("SQLite schema error: " .. tostring(result and result.message or result))
    end
    if rows[1].count ~= 0 then
      error("Workbench operation records must be cleared before schema v4")
    end

    execute(db, [[
      CREATE TABLE operations_v4 (
        workspace_id TEXT NOT NULL,
        operation_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision >= 0),
        command_digest BLOB NOT NULL,
        result BLOB NOT NULL,
        created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (workspace_id, operation_id),
        FOREIGN KEY (workspace_id) REFERENCES workspaces(id) ON DELETE CASCADE
          DEFERRABLE INITIALLY DEFERRED
      )
    ]])
    execute(db, "DROP TABLE operations")
    execute(db, "ALTER TABLE operations_v4 RENAME TO operations")
    execute(db, [[
      CREATE INDEX operations_workspace_id ON operations(workspace_id, revision)
    ]])
  end,
}
