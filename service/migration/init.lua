local migrations = {
  require "plugins.workbench.service.migration.003_schema",
}

local Migration = {}

local function error_message(result)
  if type(result) == "table" then
    return string.format("SQLite error %s (%s/%s): %s",
      tostring(result.name or "error"), tostring(result.code or "?"),
      tostring(result.extended_code or "?"), tostring(result.message or "unknown error"))
  end
  return tostring(result)
end

local function execute(db, sql, parameters)
  local ok, result = db:execute(sql, parameters)
  if not ok then error(error_message(result)) end
  return ok
end

local function query(db, sql, parameters)
  local rows, result = db:query(sql, parameters)
  if not rows then error(error_message(result)) end
  return rows
end

local function transaction(db, method, ...)
  local ok, result = db[method](db, ...)
  if not ok then error(error_message(result)) end
  return ok
end

function Migration.apply(db)
  execute(db, [[
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
      application_version TEXT NOT NULL DEFAULT 'workbench-v2'
    )
  ]])

  local applied = {}
  for _, row in ipairs(query(db, "SELECT version FROM schema_migrations")) do
    if row.version ~= 3 then
      error("unsupported Workbench schema version " .. tostring(row.version)
        .. "; this database must be recreated")
    end
    applied[row.version] = true
  end

  table.sort(migrations, function(a, b) return a.version < b.version end)
  for _, migration in ipairs(migrations) do
    if not applied[migration.version] then
      transaction(db, "begin", "immediate")
      local ok, message = pcall(migration.up, db)
      if ok then
        ok, message = pcall(function()
          execute(db, [[
            INSERT INTO schema_migrations(version, application_version)
            VALUES (?, 'workbench-v2')
          ]], { migration.version })
        end)
      end
      if ok then
        ok, message = pcall(function() transaction(db, "commit") end)
      else
        pcall(function() transaction(db, "rollback") end)
        error(error_message(message))
      end
      if not ok then error(error_message(message)) end
    end
  end

  local foreign_key_errors = query(db, "PRAGMA foreign_key_check")
  if #foreign_key_errors > 0 then
    error("Workbench schema foreign key check failed")
  end
  local quick_check = query(db, "PRAGMA quick_check")
  if #quick_check ~= 1 or quick_check[1].quick_check ~= "ok" then
    error("Workbench schema integrity check failed")
  end
end

return Migration
