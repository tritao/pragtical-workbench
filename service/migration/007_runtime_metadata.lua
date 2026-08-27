local function execute(db, sql, parameters)
  local ok, result = db:execute(sql, parameters)
  if not ok then
    local message = type(result) == "table" and result.message or result
    error("SQLite schema error: " .. tostring(message))
  end
end

return {
  version = 7,

  up = function(db)
    execute(db, [[
      ALTER TABLE runtimes ADD COLUMN provider TEXT
    ]])
    execute(db, [[
      ALTER TABLE runtimes ADD COLUMN external_session_id TEXT
    ]])
    execute(db, [[
      ALTER TABLE runtimes ADD COLUMN capabilities BLOB NOT NULL DEFAULT X'80'
    ]])
    execute(db, [[
      ALTER TABLE runtimes ADD COLUMN execution_policy BLOB NOT NULL DEFAULT X'80'
    ]])
  end,
}
