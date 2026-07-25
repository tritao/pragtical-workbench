local Runtime = {}

local active = {}

function Runtime.key(client, terminal_id)
  return tostring(client.backend or "unknown") .. ":"
    .. tostring(client.workspace_id or "default") .. ":" .. terminal_id
end

function Runtime.get(client, terminal_id)
  return active[Runtime.key(client, terminal_id)]
end

function Runtime.set(client, terminal_id, state)
  active[Runtime.key(client, terminal_id)] = state
  return state
end

function Runtime.remove(client, terminal_id)
  local key = Runtime.key(client, terminal_id)
  local state = active[key]
  active[key] = nil
  return state
end

return Runtime
