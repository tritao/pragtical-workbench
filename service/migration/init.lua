local migrations = {
  require "plugins.workbench.service.migration.001_initial",
  require "plugins.workbench.service.migration.002_runtime_metadata",
}

local Migration = {}

function Migration.apply(db)
  db:execute [[
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
  ]]

  local applied = {}
  for _, row in ipairs(db:query("SELECT version FROM schema_migrations")) do
    applied[row.version] = true
  end

  table.sort(migrations, function(a, b) return a.version < b.version end)
  for _, migration in ipairs(migrations) do
    if not applied[migration.version] then
      db:execute("BEGIN")
      local ok, message = pcall(migration.up, db)
      if ok then
        ok, message = pcall(function()
          db:execute("INSERT INTO schema_migrations(version) VALUES (?)", {
            migration.version
          })
        end)
      end
      if ok then
        db:execute("COMMIT")
      else
        pcall(function() db:execute("ROLLBACK") end)
        error(message)
      end
    end
  end
end

return Migration
