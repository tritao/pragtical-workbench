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

local function upsert_record(records, by_id, record)
  if not record or not record.id then return nil end
  local current = by_id[record.id]
  if current then
    for key in pairs(current) do current[key] = nil end
    for key, value in pairs(record) do current[key] = value end
    return current
  end
  local copy = copy_record(record)
  records[#records + 1] = copy
  by_id[copy.id] = copy
  return copy
end

local function remove_record(records, by_id, id)
  if not id then return false end
  if not by_id[id] then return false end
  by_id[id] = nil
  for index, record in ipairs(records) do
    if record.id == id then
      table.remove(records, index)
      return true
    end
  end
  return true
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
  self.name = snapshot.name or self.workspace_id
  self.revision = snapshot.revision or 0
  self.collections = {}
  self.collection_by_id = {}
  self.tasks = {}
  self.task_by_id = {}
  self.terminals = {}
  self.terminal_by_id = {}
  self.runtimes = {}
  self.runtime_by_id = {}
  self.provider_metadata = {}
  self.provider_metadata_by_id = {}
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
  for _, runtime in ipairs(snapshot.runtimes or {}) do
    local copy = copy_record(runtime)
    self.runtimes[#self.runtimes + 1] = copy
    self.runtime_by_id[copy.id] = copy
  end
  for _, metadata in ipairs(snapshot.provider_metadata or {}) do
    local copy = copy_record(metadata)
    local id = copy.provider_id or copy.id
    if id then
      copy.id = copy.id or id
      self.provider_metadata[#self.provider_metadata + 1] = copy
      self.provider_metadata_by_id[id] = copy
    end
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
    upsert_record(self.collections, self.collection_by_id, event.record or {
      id = event.entity_id, parent_id = event.parent_id or "root",
      title = event.title or "", order = #self.collections,
    })
  elseif event_type == "collection.updated" or event_type == "collection.moved"
      or event_type == "collection.archived" then
    if not upsert_record(self.collections, self.collection_by_id, event.record) then
      self.needs_snapshot = true
    end
  elseif event_type == "collection.deleted" then
    remove_record(self.collections, self.collection_by_id, event.entity_id)
  elseif event_type == "task.created" then
    upsert_record(self.tasks, self.task_by_id, event.record or {
      id = event.entity_id, title = event.title or "", order = #self.tasks,
    })
  elseif event_type == "task.updated" or event_type == "task.moved"
      or event_type == "task.archived" then
    if not upsert_record(self.tasks, self.task_by_id, event.record) then
      self.needs_snapshot = true
    end
  elseif event_type == "task.deleted" then
    remove_record(self.tasks, self.task_by_id, event.entity_id)
  elseif event_type == "resource.created" then
    local resource = upsert_record(self.terminals, self.terminal_by_id, event.record or {
      id = event.entity_id, kind = event.kind or "terminal",
      provider = event.provider, title = event.title or "", status = "stopped",
    })
    if resource and resource.kind ~= "terminal" then
      remove_record(self.terminals, self.terminal_by_id, resource.id)
    end
  elseif event_type == "resource.updated" or event_type == "resource.archived"
      or event_type == "runtime.status_changed" then
    local resource = event.record
    if not resource or not resource.id then
      self.needs_snapshot = true
    elseif resource.kind == "terminal" then
      upsert_record(self.terminals, self.terminal_by_id, resource)
    else
      remove_record(self.terminals, self.terminal_by_id, resource.id)
    end
  elseif event_type == "resource.deleted" then
    remove_record(self.terminals, self.terminal_by_id, event.entity_id)
  elseif event_type == "runtime.updated" then
    if not upsert_record(self.runtimes, self.runtime_by_id, event.record) then
      self.needs_snapshot = true
    end
    if event.resource then
      upsert_record(self.terminals, self.terminal_by_id, event.resource)
    elseif event.resource_id and self.terminal_by_id[event.resource_id] then
      self.terminal_by_id[event.resource_id].status = event.status
    end
  elseif event_type == "runtime.deleted" then
    remove_record(self.runtimes, self.runtime_by_id, event.entity_id)
  elseif event_type == "provider.metadata_updated" then
    local metadata = event.record and copy_record(event.record)
    if metadata then metadata.id = metadata.id or metadata.provider_id end
    if not upsert_record(self.provider_metadata, self.provider_metadata_by_id,
        metadata) then
      self.needs_snapshot = true
    end
  elseif event_type == "workspace.renamed" then
    self.name = event.name or (event.record and event.record.name) or self.name
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
    if terminal.status == "starting" or terminal.status == "running"
        or terminal.status == "stopping" or terminal.status == "recovering" then
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
