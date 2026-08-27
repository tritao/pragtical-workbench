local function execute(db, sql, parameters)
  local ok, result = db:execute(sql, parameters)
  if not ok then
    local message = type(result) == "table" and result.message or result
    error("SQLite schema error: " .. tostring(message))
  end
end

return {
  version = 5,

  up = function(db)
    execute(db, [[
      ALTER TABLE workspaces
        ADD COLUMN event_sequence INTEGER NOT NULL DEFAULT 0
          CHECK(event_sequence >= 0)
    ]])
    execute(db, [[
      ALTER TABLE events
        ADD COLUMN event_sequence INTEGER NOT NULL DEFAULT 0
          CHECK(event_sequence >= 0)
    ]])
    -- Existing v4 rows receive a stable cursor derived from their durable
    -- event identity. New writes use the explicit cursor maintained by the
    -- authoritative service.
    execute(db, "UPDATE events SET event_sequence = event_id")
    execute(db, [[
      UPDATE workspaces
         SET event_sequence = COALESCE((
           SELECT MAX(event_sequence) FROM events
            WHERE events.workspace_id = workspaces.id
         ), 0)
    ]])
    execute(db, [[
      CREATE UNIQUE INDEX events_workspace_event_sequence
        ON events(workspace_id, event_sequence)
    ]])
  end,
}
