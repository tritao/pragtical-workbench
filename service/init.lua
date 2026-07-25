local validation = require "plugins.workbench.service.validation"

local Service = {}
Service.__index = Service

local DEFAULT_EVENT_LIMIT = 4096

local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, item in pairs(value) do
    result[copy(key, seen)] = copy(item, seen)
  end
  return result
end

local function merge(base, override)
  local result = copy(base or {})
  for key, value in pairs(override or {}) do
    result[key] = copy(value)
  end
  return result
end

local function sorted_records(records)
  local result = {}
  for _, record in pairs(records) do
    result[#result + 1] = copy(record)
  end
  table.sort(result, function(a, b)
    if (a.order or 0) ~= (b.order or 0) then
      return (a.order or 0) < (b.order or 0)
    end
    if (a.title or "") ~= (b.title or "") then
      return (a.title or "") < (b.title or "")
    end
    return tostring(a.id) < tostring(b.id)
  end)
  return result
end

local function payload(command, key)
  return merge(command, command[key])
end

local function valid_field(check, value, field)
  local ok, message = check(value, field)
  if not ok then return nil, message end
  return true
end

function Service.new(options)
  options = options or {}
  local workspace_id = options.workspace_id or options.workspace or "default"
  local persisted = options.store and options.store:load(workspace_id)
  local event_limit = options.event_limit or DEFAULT_EVENT_LIMIT
  local service = setmetatable({
    workspace_id = workspace_id,
    name = options.name or workspace_id,
    revision = 0,
    sequence = 0,
    collections = {},
    tasks = {},
    resources = {},
    runtimes = {},
    provider_metadata = {},
    operations = {},
    listeners = {},
    events = {},
    event_offset = 0,
    event_limit = event_limit,
    store = options.store,
  }, Service)
  if persisted then
    service.name = persisted.name or service.name
    service.revision = persisted.revision or 0
    service.sequence = persisted.sequence or 0
    service.collections = persisted.collections or {}
    service.tasks = persisted.tasks or {}
    service.resources = persisted.resources or {}
    service.runtimes = persisted.runtimes or {}
    for _, runtime in pairs(service.runtimes) do
      if runtime.resource_id and service.resources[runtime.resource_id]
          and runtime.status then
        service.resources[runtime.resource_id].status = runtime.status
      end
    end
    service.provider_metadata = persisted.provider_metadata or {}
    service.operations = persisted.operations or {}
    service.events = persisted.events or {}
    service.event_offset = persisted.event_offset or 0
  end
  while #service.events > service.event_limit do
    table.remove(service.events, 1)
    service.event_offset = service.event_offset + 1
  end
  return service
end

function Service:_next_id(prefix)
  self.sequence = self.sequence + 1
  return prefix .. "-" .. tostring(self.sequence)
end

function Service:_error(code, message, operation_id)
  return {
    code = code,
    message = message,
    operation_id = operation_id,
    revision = self.revision,
  }
end

function Service:_require_record(records, id, kind)
  local record = records[id]
  if not record then
    return nil, self:_error("not_found", kind .. " not found: " .. tostring(id))
  end
  return record
end

function Service:_next_order(records, parent_key, parent_field)
  local maximum = -1
  for _, record in pairs(records) do
    if parent_field == nil or (record[parent_field] or "root") == parent_key then
      maximum = math.max(maximum, record.order or -1)
    end
  end
  return maximum + 1
end

function Service:_state()
  return {
    name = self.name,
    revision = self.revision,
    sequence = self.sequence,
    collections = copy(self.collections),
    tasks = copy(self.tasks),
    resources = copy(self.resources),
    runtimes = copy(self.runtimes),
    provider_metadata = copy(self.provider_metadata),
    operations = copy(self.operations),
    events = copy(self.events),
    event_offset = self.event_offset,
  }
end

function Service:_restore(state)
  self.name = state.name
  self.revision = state.revision
  self.sequence = state.sequence
  self.collections = state.collections
  self.tasks = state.tasks
  self.resources = state.resources
  self.runtimes = state.runtimes
  self.provider_metadata = state.provider_metadata
  self.operations = state.operations
  self.events = state.events
  self.event_offset = state.event_offset
end

function Service:_commit(operation_id, changes, extra)
  self.revision = self.revision + 1
  local emitted = {}
  for _, event in ipairs(changes) do
    event.revision = self.revision
    event.workspace_id = self.workspace_id
    self.events[#self.events + 1] = copy(event)
    emitted[#emitted + 1] = event
  end
  while #self.events > self.event_limit do
    table.remove(self.events, 1)
    self.event_offset = self.event_offset + 1
  end
  local first_event_offset = self.event_offset + #self.events - #emitted
  for index, event in ipairs(emitted) do
    event.offset = first_event_offset + index - 1
  end

  local result = merge({
    code = "ok",
    operation_id = operation_id,
    revision = self.revision,
    events = emitted,
  }, extra)

  if self.store then
    local ok, message = self.store:commit(self, operation_id, result, emitted)
    if not ok then
      return self:_error("storage_error", message, operation_id)
    end
  end
  self.operations[operation_id] = copy(result)

  for _, event in ipairs(emitted) do
    for _, callback in pairs(self.listeners) do
      callback(copy(event))
    end
  end
  return result
end

function Service:subscribe(callback)
  assert(type(callback) == "function", "Workbench event callback must be a function")
  self.listeners[#self.listeners + 1] = callback
  local active = true
  return function()
    if not active then return end
    active = false
    for index, listener in ipairs(self.listeners) do
      if listener == callback then
        table.remove(self.listeners, index)
        break
      end
    end
  end
end

function Service:snapshot()
  local resources = sorted_records(self.resources)
  local terminals = {}
  for _, resource in ipairs(resources) do
    if resource.kind == "terminal" then
      terminals[#terminals + 1] = copy(resource)
    end
  end
  return {
    workspace_id = self.workspace_id,
    name = self.name,
    revision = self.revision,
    collections = sorted_records(self.collections),
    tasks = sorted_records(self.tasks),
    resources = resources,
    terminals = terminals,
    runtimes = sorted_records(self.runtimes),
    provider_metadata = sorted_records(self.provider_metadata),
    event_offset = self.event_offset,
  }
end

function Service:get_events(offset)
  offset = offset or 0
  if offset < self.event_offset then
    return nil, {
      code = "snapshot_required",
      oldest_offset = self.event_offset,
      revision = self.revision,
    }
  end
  local result = {}
  local index = offset - self.event_offset + 1
  for current = index, #self.events do
    result[#result + 1] = copy(self.events[current])
  end
  return result
end

function Service:poll()
  return {}
end

function Service:close()
  if self.store then
    self.store:close()
    self.store = nil
  end
end

function Service:_create_collection(command, changes)
  local value = payload(command, "collection")
  local id = value.id or self:_next_id("collection")
  local ok, message = valid_field(validation.id, id, "collection.id")
  if not ok then return nil, message end
  if self.collections[id] then return nil, "collection already exists: " .. id end
  ok, message = valid_field(validation.title, value.title, "collection.title")
  if not ok then return nil, message end

  local parent_id = value.parent_id or "root"
  if parent_id ~= "root" and not self.collections[parent_id] then
    return nil, "parent collection not found: " .. tostring(parent_id)
  end
  self.collections[id] = {
    id = id,
    parent_id = parent_id,
    title = value.title,
    order = value.order or self:_next_order(self.collections, parent_id, "parent_id"),
    archived = value.archived == true,
  }
  changes[#changes + 1] = {
    type = "collection.created",
    entity_type = "collection",
    entity_id = id,
    parent_id = parent_id,
    title = value.title,
  }
  return {entity_id = id}
end

function Service:_update_collection(command, changes)
  local value = payload(command, "collection")
  local id = value.collection_id or value.id
  local collection, error_result = self:_require_record(self.collections, id, "collection")
  if not collection then return nil, error_result.message end
  local changed = false
  if value.title ~= nil then
    local ok, message = valid_field(validation.title, value.title, "collection.title")
    if not ok then return nil, message end
    collection.title, changed = value.title, true
  end
  if value.parent_id ~= nil then
    if value.parent_id ~= "root" and not self.collections[value.parent_id] then
      return nil, "parent collection not found: " .. tostring(value.parent_id)
    end
    collection.parent_id, changed = value.parent_id, true
  end
  if value.order ~= nil then
    local ok, message = valid_field(validation.integer, value.order, "collection.order")
    if not ok then return nil, message end
    collection.order, changed = value.order, true
  end
  if not changed then return nil, "collection update has no changes" end
  changes[#changes + 1] = {
    type = value.parent_id and "collection.moved" or "collection.updated",
    entity_type = "collection",
    entity_id = id,
    parent_id = collection.parent_id,
    title = collection.title,
    order = collection.order,
  }
  return {entity_id = id}
end

function Service:_archive_collection(command, changes)
  local id = command.collection_id or command.id
  local collection, error_result = self:_require_record(self.collections, id, "collection")
  if not collection then return nil, error_result.message end
  collection.archived = command.archived ~= false
  changes[#changes + 1] = {
    type = "collection.archived",
    entity_type = "collection",
    entity_id = id,
    archived = collection.archived,
  }
  return {entity_id = id}
end

function Service:_delete_collection(command, changes)
  local id = command.collection_id or command.id
  local collection, error_result = self:_require_record(self.collections, id, "collection")
  if not collection then return nil, error_result.message end
  self.collections[id] = nil
  for _, task in pairs(self.tasks) do
    if task.collection_id == id then task.collection_id = nil end
  end
  for _, resource in pairs(self.resources) do
    if resource.collection_id == id then resource.collection_id = nil end
  end
  changes[#changes + 1] = {
    type = "collection.deleted",
    entity_type = "collection",
    entity_id = id,
  }
  return {entity_id = id}
end

function Service:_create_task(command, changes)
  local value = payload(command, "task")
  local id = value.id or self:_next_id("task")
  local ok, message = valid_field(validation.id, id, "task.id")
  if not ok then return nil, message end
  if self.tasks[id] then return nil, "task already exists: " .. id end
  ok, message = valid_field(validation.title, value.title, "task.title")
  if not ok then return nil, message end
  if value.collection_id and not self.collections[value.collection_id] then
    return nil, "collection not found: " .. tostring(value.collection_id)
  end
  self.tasks[id] = {
    id = id,
    collection_id = value.collection_id,
    title = value.title,
    status = value.status or "active",
    order = value.order or self:_next_order(self.tasks),
    archived = value.archived == true,
  }
  changes[#changes + 1] = {
    type = "task.created",
    entity_type = "task",
    entity_id = id,
    title = value.title,
  }
  return {entity_id = id}
end

function Service:_update_task(command, changes)
  local value = payload(command, "task")
  local id = value.task_id or value.id
  local task, error_result = self:_require_record(self.tasks, id, "task")
  if not task then return nil, error_result.message end
  local changed = false
  if value.title ~= nil then
    local ok, message = valid_field(validation.title, value.title, "task.title")
    if not ok then return nil, message end
    task.title, changed = value.title, true
  end
  if value.collection_id ~= nil then
    if value.collection_id ~= "" and not self.collections[value.collection_id] then
      return nil, "collection not found: " .. tostring(value.collection_id)
    end
    task.collection_id = value.collection_id ~= "" and value.collection_id or nil
    changed = true
  end
  if value.status ~= nil then task.status, changed = value.status, true end
  if value.order ~= nil then
    local ok, message = valid_field(validation.integer, value.order, "task.order")
    if not ok then return nil, message end
    task.order, changed = value.order, true
  end
  if not changed then return nil, "task update has no changes" end
  changes[#changes + 1] = {
    type = value.collection_id and "task.moved" or "task.updated",
    entity_type = "task",
    entity_id = id,
    title = task.title,
    collection_id = task.collection_id,
    status = task.status,
    order = task.order,
  }
  return {entity_id = id}
end

function Service:_archive_task(command, changes)
  local id = command.task_id or command.id
  local task, error_result = self:_require_record(self.tasks, id, "task")
  if not task then return nil, error_result.message end
  task.archived = command.archived ~= false
  changes[#changes + 1] = {
    type = "task.archived",
    entity_type = "task",
    entity_id = id,
    archived = task.archived,
  }
  return {entity_id = id}
end

function Service:_delete_task(command, changes)
  local id = command.task_id or command.id
  local task, error_result = self:_require_record(self.tasks, id, "task")
  if not task then return nil, error_result.message end
  self.tasks[id] = nil
  changes[#changes + 1] = {
    type = "task.deleted",
    entity_type = "task",
    entity_id = id,
  }
  return {entity_id = id}
end

function Service:_create_resource(command, changes)
  local value = payload(command, "resource")
  if command.terminal then value = merge(value, command.terminal) end
  local id = value.id or self:_next_id("resource")
  local ok, message = valid_field(validation.id, id, "resource.id")
  if not ok then return nil, message end
  if self.resources[id] then return nil, "resource already exists: " .. id end
  ok, message = valid_field(validation.title, value.title, "resource.title")
  if not ok then return nil, message end
  if value.collection_id and not self.collections[value.collection_id] then
    return nil, "collection not found: " .. tostring(value.collection_id)
  end
  local kind = value.kind or "terminal"
  self.resources[id] = {
    id = id,
    kind = kind,
    provider = value.provider or (kind == "terminal" and "builtin.shell" or nil),
    title = value.title,
    collection_id = value.collection_id,
    config = copy(value.config or {}),
    status = value.status or "stopped",
    cols = value.cols or value.columns or 80,
    rows = value.rows or 24,
    order = value.order or self:_next_order(self.resources),
    archived = value.archived == true,
  }
  changes[#changes + 1] = {
    type = "resource.created",
    entity_type = "resource",
    entity_id = id,
    kind = kind,
    title = value.title,
  }
  return {entity_id = id}
end

function Service:_update_resource(command, changes)
  local value = payload(command, "resource")
  if command.terminal then value = merge(value, command.terminal) end
  local id = value.resource_id or value.terminal_id or value.id
  local resource, error_result = self:_require_record(self.resources, id, "resource")
  if not resource then return nil, error_result.message end
  local changed = false
  if value.title ~= nil then
    local ok, message = valid_field(validation.title, value.title, "resource.title")
    if not ok then return nil, message end
    resource.title, changed = value.title, true
  end
  if value.collection_id ~= nil then
    if value.collection_id ~= "" and not self.collections[value.collection_id] then
      return nil, "collection not found: " .. tostring(value.collection_id)
    end
    resource.collection_id = value.collection_id ~= "" and value.collection_id or nil
    changed = true
  end
  if value.status ~= nil then resource.status, changed = value.status, true end
  if value.cols ~= nil then
    local ok, message = valid_field(validation.integer, value.cols, "resource.cols")
    if not ok then return nil, message end
    resource.cols, changed = value.cols, true
  end
  if value.rows ~= nil then
    local ok, message = valid_field(validation.integer, value.rows, "resource.rows")
    if not ok then return nil, message end
    resource.rows, changed = value.rows, true
  end
  if value.config ~= nil then resource.config, changed = copy(value.config), true end
  if not changed then return nil, "resource update has no changes" end
  changes[#changes + 1] = {
    type = value.status and "runtime.status_changed" or "resource.updated",
    entity_type = "resource",
    entity_id = id,
    kind = resource.kind,
    title = resource.title,
    status = resource.status,
    cols = resource.cols,
    rows = resource.rows,
  }
  return {entity_id = id}
end

function Service:_update_runtime(command, changes)
  local value = payload(command, "runtime")
  local id = value.runtime_id or value.id
  local ok, message = valid_field(validation.id, id, "runtime.id")
  if not ok then return nil, message end

  local runtime = self.runtimes[id] or { id = id, metadata = {} }
  if value.resource_id ~= nil then
    if not self.resources[value.resource_id] then
      return nil, "resource not found: " .. tostring(value.resource_id)
    end
    runtime.resource_id = value.resource_id
  end

  for _, field in ipairs {
    "status", "started_at", "ended_at", "history_path"
  } do
    if value[field] ~= nil then runtime[field] = value[field] end
  end
  for _, field in ipairs {
    "pid", "output_bytes", "output_offset"
  } do
    if value[field] ~= nil then
      ok, message = valid_field(validation.integer, value[field], "runtime." .. field)
      if not ok then return nil, message end
      runtime[field] = value[field]
    end
  end
  if value.metadata ~= nil then runtime.metadata = copy(value.metadata) end
  self.runtimes[id] = runtime
  if runtime.resource_id and self.resources[runtime.resource_id] and runtime.status then
    self.resources[runtime.resource_id].status = runtime.status
  end
  changes[#changes + 1] = {
    type = "runtime.updated",
    entity_type = "runtime",
    entity_id = id,
    resource_id = runtime.resource_id,
    status = runtime.status,
    output_offset = runtime.output_offset,
  }
  return {runtime_id = id}
end

function Service:_update_provider_metadata(command, changes)
  local value = payload(command, "provider")
  local id = value.provider_id or value.id
  local ok, message = valid_field(validation.id, id, "provider.id")
  if not ok then return nil, message end
  if value.metadata == nil then return nil, "provider metadata is required" end
  self.provider_metadata[id] = {
    provider_id = id,
    metadata = copy(value.metadata),
  }
  changes[#changes + 1] = {
    type = "provider.metadata_updated",
    entity_type = "provider",
    entity_id = id,
  }
  return {provider_id = id}
end

function Service:_archive_resource(command, changes)
  local id = command.resource_id or command.terminal_id or command.id
  local resource, error_result = self:_require_record(self.resources, id, "resource")
  if not resource then return nil, error_result.message end
  resource.archived = command.archived ~= false
  changes[#changes + 1] = {
    type = "resource.archived",
    entity_type = "resource",
    entity_id = id,
    archived = resource.archived,
  }
  return {entity_id = id}
end

function Service:_delete_resource(command, changes)
  local id = command.resource_id or command.terminal_id or command.id
  local resource, error_result = self:_require_record(self.resources, id, "resource")
  if not resource then return nil, error_result.message end
  self.resources[id] = nil
  changes[#changes + 1] = {
    type = "resource.deleted",
    entity_type = "resource",
    entity_id = id,
  }
  return {entity_id = id}
end

function Service:_rename_workspace(command, changes)
  local name = command.name or command.title
  local ok, message = valid_field(validation.title, name, "workspace.name")
  if not ok then return nil, message end
  self.name = name
  changes[#changes + 1] = {
    type = "workspace.renamed",
    entity_type = "workspace",
    entity_id = self.workspace_id,
    name = name,
  }
  return {entity_id = self.workspace_id}
end

function Service:execute(command)
  local ok, message = validation.command(command)
  if not ok then return self:_error("invalid_command", message) end

  local operation_id = command.operation_id or command.id
    or self:_next_id("operation")
  local previous = self.operations[operation_id]
  if previous then return copy(previous) end

  if command.workspace_id and command.workspace_id ~= self.workspace_id then
    return self:_error("workspace_mismatch",
      "command workspace does not match client workspace", operation_id)
  end
  if command.expected_revision ~= nil and command.expected_revision ~= self.revision then
    return self:_error("revision_conflict",
      "expected revision " .. tostring(command.expected_revision)
      .. ", current revision is " .. tostring(self.revision), operation_id)
  end

  local checkpoint = self.store and self:_state()
  local changes = {}
  local result, handler_message
  local command_type = command.type
  if command_type == "workspace.create" or command_type == "workspace.rename" then
    result, handler_message = self:_rename_workspace(command, changes)
  elseif command_type == "collection.create" then
    result, handler_message = self:_create_collection(command, changes)
  elseif command_type == "collection.rename" or command_type == "collection.move"
      or command_type == "collection.update" then
    result, handler_message = self:_update_collection(command, changes)
  elseif command_type == "collection.archive" then
    result, handler_message = self:_archive_collection(command, changes)
  elseif command_type == "collection.delete" then
    result, handler_message = self:_delete_collection(command, changes)
  elseif command_type == "task.create" then
    result, handler_message = self:_create_task(command, changes)
  elseif command_type == "task.update" or command_type == "task.move" then
    result, handler_message = self:_update_task(command, changes)
  elseif command_type == "task.archive" then
    result, handler_message = self:_archive_task(command, changes)
  elseif command_type == "task.delete" then
    result, handler_message = self:_delete_task(command, changes)
  elseif command_type == "resource.create" or command_type == "terminal.create" then
    result, handler_message = self:_create_resource(command, changes)
  elseif command_type == "resource.update" or command_type == "resource.attach"
      or command_type == "resource.detach" or command_type == "terminal.update"
      or command_type == "terminal.status" then
    result, handler_message = self:_update_resource(command, changes)
  elseif command_type == "runtime.update" or command_type == "runtime.start"
      or command_type == "runtime.stop" or command_type == "runtime.restart" then
    result, handler_message = self:_update_runtime(command, changes)
  elseif command_type == "provider.metadata.update" then
    result, handler_message = self:_update_provider_metadata(command, changes)
  elseif command_type == "resource.archive" then
    result, handler_message = self:_archive_resource(command, changes)
  elseif command_type == "resource.delete" or command_type == "terminal.delete"
      or command_type == "runtime.delete_history" then
    result, handler_message = self:_delete_resource(command, changes)
  else
    return self:_error("unsupported_command",
      "unsupported Workbench command: " .. command_type, operation_id)
  end

  if not result then
    return self:_error("invalid_command", handler_message, operation_id)
  end
  local committed = self:_commit(operation_id, changes, result)
  if committed.code == "storage_error" and checkpoint then
    self:_restore(checkpoint)
  end
  return committed
end

return Service
