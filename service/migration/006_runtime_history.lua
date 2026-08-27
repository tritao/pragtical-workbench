local function execute(db, sql, parameters)
  local ok, result = db:execute(sql, parameters)
  if not ok then
    local message = type(result) == "table" and result.message or result
    error("SQLite schema error: " .. tostring(message))
  end
end

return {
  version = 6,

  up = function(db)
    execute(db, [[
      ALTER TABLE runtimes
        ADD COLUMN oldest_offset INTEGER NOT NULL DEFAULT 0
          CHECK(oldest_offset >= 0)
    ]])
    execute(db, [[
      ALTER TABLE runtimes
        ADD COLUMN newest_offset INTEGER NOT NULL DEFAULT 0
          CHECK(newest_offset >= 0)
    ]])
    execute(db, [[
      ALTER TABLE runtimes
        ADD COLUMN max_history_bytes INTEGER NOT NULL DEFAULT 16777216
          CHECK(max_history_bytes > 0)
    ]])
    execute(db, [[
      ALTER TABLE runtimes ADD COLUMN checkpoint_path TEXT
    ]])
    execute(db, [[
      ALTER TABLE runtimes
        ADD COLUMN checkpoint_offset INTEGER NOT NULL DEFAULT 0
          CHECK(checkpoint_offset >= 0)
    ]])
    execute(db, [[
      UPDATE runtimes
         SET newest_offset = output_offset,
             oldest_offset = 0
    ]])
  end,
}
