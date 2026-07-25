local Model = {}
Model.__index = Model

local function copy_record(record)
  local copy = {}
  for key, value in pairs(record or {}) do
    copy[key] = value
  end
  return copy
end

local function compare_records(a, b)
  if (a.order or 0) ~= (b.order or 0) then
    return (a.order or 0) < (b.order or 0)
  end
  if (a.title or "") ~= (b.title or "") then
    return (a.title or "") < (b.title or "")
  end
  return a.id < b.id
end

local function matches_parent(record, parent_id)
  local record_parent = record.parent_id
  if record_parent == nil or record_parent == "" then
    record_parent = "root"
  end
  return record_parent == parent_id
end

function Model.new(snapshot)
  local model = setmetatable({
    expanded = {},
    rows = {},
    needs_snapshot = false
  }, Model)
  model:replace(snapshot or {})
  return model
end

function Model:replace(snapshot)
  local expanded = self.expanded or {}
  self.workspace_id = snapshot.workspace_id or "default"
  self.revision = snapshot.revision or 0
  self.collections = {}
  self.collection_by_id = {}
  self.tasks = {}
  self.task_by_id = {}
  self.terminals = {}
  self.terminal_by_id = {}
  self.expanded = expanded
  self.needs_snapshot = false

  for _, collection in ipairs(snapshot.collections or {}) do
    local copy = copy_record(collection)
    self.collections[#self.collections + 1] = copy
    self.collection_by_id[copy.id] = copy
  end
  for _, task in ipairs(snapshot.tasks or {}) do
    local copy = copy_record(task)
    self.tasks[#self.tasks + 1] = copy
    self.task_by_id[copy.id] = copy
  end
  for _, terminal in ipairs(snapshot.terminals or {}) do
    local copy = copy_record(terminal)
    self.terminals[#self.terminals + 1] = copy
    self.terminal_by_id[copy.id] = copy
  end
  self:rebuild()
end

function Model:set_expanded(id, expanded)
  self.expanded[id] = expanded
  self:rebuild()
end

function Model:is_expanded(id)
  return self.expanded[id] ~= false
end

function Model:apply_event(event)
  self.needs_snapshot = false
  local event_type = event.type

  if event_type == "collection.created" then
    if not self.collection_by_id[event.entity_id] then
      local collection = {
        id = event.entity_id,
        parent_id = event.parent_id or "root",
        title = event.title or "",
        order = #self.collections
      }
      self.collections[#self.collections + 1] = collection
      self.collection_by_id[collection.id] = collection
    end
  elseif event_type == "collection.updated" then
    local collection = self.collection_by_id[event.entity_id]
    if collection then
      collection.title = event.title or collection.title
    else
      self.needs_snapshot = true
    end
  elseif event_type == "collection.moved" then
    local collection = self.collection_by_id[event.entity_id]
    if collection then
      collection.parent_id = event.parent_id or "root"
    else
      self.needs_snapshot = true
    end
  elseif event_type == "collection.deleted" then
    self.needs_snapshot = true
  elseif event_type == "collection.archived" then
    -- The compact event does not carry the new archived value. Refresh so
    -- both archive and unarchive remain correct.
    self.needs_snapshot = true
  elseif event_type == "task.created"
      or event_type == "task.updated"
      or event_type == "task.moved"
      or event_type == "task.archived"
      or event_type == "task.deleted"
      or event_type == "resource.created"
      or event_type == "resource.updated"
      or event_type == "resource.deleted"
      or event_type == "runtime.status_changed" then
    self.needs_snapshot = true
  else
    self.needs_snapshot = true
  end

  self.revision = event.revision or self.revision
  self:rebuild()
  return not self.needs_snapshot
end

function Model:_append_collection_rows(rows, parent_id, depth, visited)
  local children = {}
  for _, collection in ipairs(self.collections) do
    if collection.id ~= "root" and matches_parent(collection, parent_id) then
      children[#children + 1] = collection
    end
  end
  table.sort(children, compare_records)

  for _, collection in ipairs(children) do
    if not visited[collection.id] then
      visited[collection.id] = true
      local expandable = false
      for _, candidate in ipairs(self.collections) do
        if candidate.id ~= "root" and matches_parent(candidate, collection.id) then
          expandable = true
          break
        end
      end
      rows[#rows + 1] = {
        kind = "collection",
        id = collection.id,
        label = collection.title ~= "" and collection.title or collection.id,
        depth = depth,
        expandable = expandable,
        expanded = self:is_expanded(collection.id),
        entity = collection
      }
      if expandable and self:is_expanded(collection.id) then
        self:_append_collection_rows(rows, collection.id, depth + 1, visited)
      end
    end
  end
end

function Model:rebuild()
  local rows = {}
  local visited = {}
  local function section(id, label)
    rows[#rows + 1] = { kind = "section", id = id, label = label, depth = 0 }
  end

  rows[#rows + 1] = {
    kind = "workspace",
    id = "workspace:" .. self.workspace_id,
    label = self.workspace_id,
    depth = 0
  }

  section("collections", "Collections")
  self:_append_collection_rows(rows, "root", 1, visited)

  section("tasks", "Tasks")
  local tasks = {}
  for _, task in ipairs(self.tasks) do
    tasks[#tasks + 1] = task
  end
  table.sort(tasks, compare_records)
  for _, task in ipairs(tasks) do
    rows[#rows + 1] = {
      kind = "task",
      id = task.id,
      label = task.title ~= "" and task.title or task.id,
      depth = 1,
      entity = task
    }
  end

  section("resources", "Resources")
  for _, terminal in ipairs(self.terminals) do
    rows[#rows + 1] = {
      kind = "terminal",
      id = terminal.id,
      label = terminal.title ~= "" and terminal.title or terminal.id,
      depth = 1,
      entity = terminal
    }
  end

  section("running", "Running sessions")
  for _, terminal in ipairs(self.terminals) do
    if terminal.status == "starting" or terminal.status == "running" then
      rows[#rows + 1] = {
        kind = "runtime",
        id = "runtime:" .. terminal.id,
        label = terminal.title ~= "" and terminal.title or terminal.id,
        depth = 1,
        entity = terminal
      }
    end
  end
  self.rows = rows
end

function Model:get_row(index)
  return self.rows[index]
end

return Model
