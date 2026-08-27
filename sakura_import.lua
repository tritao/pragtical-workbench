-- Independent importer for Sakura's persisted GKeyFile session format.
--
-- This module deliberately does not require Sakura, GTK, or GLib.  The
-- source file is treated as an external migration input and is never written
-- by the importer.

local Importer = {}

local function trim(value)
  return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unescape(value)
  local result = {}
  local index = 1
  while index <= #value do
    local character = value:sub(index, index)
    if character ~= "\\" or index == #value then
      result[#result + 1] = character
      index = index + 1
    else
      local escaped = value:sub(index + 1, index + 1)
      local replacement = {
        ["s"] = " ",
        ["n"] = "\n",
        ["t"] = "\t",
        ["r"] = "\r",
        ["\\"] = "\\",
        [";"] = ";",
        ["="] = "=",
      }
      result[#result + 1] = replacement[escaped] or escaped
      index = index + 2
    end
  end
  return table.concat(result)
end

local function parse_key_file(data)
  if type(data) ~= "string" then
    return nil, "Sakura session data must be a string"
  end

  local sections = {}
  local section
  local line_number = 0
  for line in (data .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    line = line:gsub("\r$", "")
    local stripped = trim(line)
    if stripped ~= "" and stripped:sub(1, 1) ~= "#"
        and stripped:sub(1, 1) ~= ";" then
      local section_name = stripped:match("^%[([^%]]+)%]$")
      if section_name then
        section_name = trim(section_name)
        if section_name == "" then
          return nil, "Sakura session line " .. tostring(line_number)
            .. " has an empty section name"
        end
        if sections[section_name] then
          return nil, "duplicate Sakura session section: " .. section_name
        end
        section = {}
        sections[section_name] = section
      else
        if not section then
          return nil, "Sakura session key appears before a section at line "
            .. tostring(line_number)
        end
        local key, value = line:match("^%s*([^=]+)=(.*)$")
        if not key then
          return nil, "malformed Sakura session key at line "
            .. tostring(line_number)
        end
        key = trim(key)
        if key == "" then
          return nil, "Sakura session line " .. tostring(line_number)
            .. " has an empty key"
        end
        if section[key] ~= nil then
          return nil, "duplicate Sakura session key: " .. key
        end
        section[key] = unescape(trim(value))
      end
    end
  end
  return sections
end

local function number(value, name, default)
  if value == nil then return default end
  local result = tonumber(value)
  if not result or result ~= math.floor(result) then
    return nil, name .. " must be an integer"
  end
  return result
end

local function boolean(value, name, default)
  if value == nil then return default end
  if value == "true" or value == "1" then return true end
  if value == "false" or value == "0" then return false end
  return nil, name .. " must be true or false"
end

local function required(section, key, name)
  local value = section and section[key]
  if value == nil or value == "" then
    return nil, name .. " is required"
  end
  return value
end

local function optional(section, key)
  local value = section and section[key]
  if value == "" then return nil end
  return value
end

local function section(sections, name, index)
  local result = sections[name .. tostring(index)]
  if not result then
    return nil, "missing Sakura session section: " .. name .. tostring(index)
  end
  return result
end

local function map_task_status(status)
  return ({
    [0] = "active",
    [1] = "working",
    [2] = "blocked",
    [3] = "review",
    [4] = "done",
  })[status] or "active"
end

local function map_terminal_kind(kind)
  if kind == "codex" then return "codex" end
  if kind == "tool" or kind == "gitui" then return "tool" end
  return "shell"
end

local function add_error(errors, message)
  errors[#errors + 1] = message
end

local function add_warning(warnings, message)
  warnings[#warnings + 1] = message
end

local function add_skipped(skipped, field, count, reason)
  skipped[#skipped + 1] = {
    field = field,
    count = count or 1,
    reason = reason,
  }
end

local function index_by_id(records)
  local result = {}
  for _, record in ipairs(records) do result[record.id] = record end
  return result
end

local function validate_collection_tree(collections, errors)
  local by_id = index_by_id(collections)
  for _, collection in ipairs(collections) do
    local parent = collection.parent_id
    local seen = {}
    while parent and parent ~= "root" do
      if seen[parent] then
        add_error(errors, "cycle in Sakura collection parents at: " .. parent)
        break
      end
      seen[parent] = true
      if not by_id[parent] then
        add_error(errors, "collection points to missing parent: " .. parent)
        break
      end
      parent = by_id[parent].parent_id
    end
  end
end

local function collection_depth(collection, by_id)
  local depth = 0
  local parent = collection.parent_id
  local seen = {}
  while parent and parent ~= "root" and not seen[parent] do
    seen[parent] = true
    local parent_record = by_id[parent]
    if not parent_record then break end
    depth = depth + 1
    parent = parent_record.parent_id
  end
  return depth
end

local function sort_collections(collections)
  local by_id = index_by_id(collections)
  table.sort(collections, function(first, second)
    local first_depth = collection_depth(first, by_id)
    local second_depth = collection_depth(second, by_id)
    if first_depth ~= second_depth then return first_depth < second_depth end
    if first.order ~= second.order then return first.order < second.order end
    return first.id < second.id
  end)
end

local function validate_records(snapshot, errors, warnings, skipped)
  local ids = {}
  for _, collection in ipairs(snapshot.collections) do
    if collection.id == "root" or ids[collection.id] then
      add_error(errors, "invalid or duplicate Sakura collection id: "
        .. tostring(collection.id))
    else
      ids[collection.id] = true
    end
  end
  validate_collection_tree(snapshot.collections, errors)

  local tasks = {}
  for _, task in ipairs(snapshot.tasks) do
    if task.id == "root" or ids[task.id] or tasks[task.id] then
      add_error(errors, "invalid or duplicate Sakura task id: " .. tostring(task.id))
    else
      tasks[task.id] = true
    end
    if task.group_id ~= "root"
        and not index_by_id(snapshot.collections)[task.group_id] then
      add_error(errors, "task points to missing collection: " .. tostring(task.group_id))
    end
    if task.parent_id ~= "root" and not tasks[task.parent_id]
        and not index_by_id(snapshot.collections)[task.parent_id] then
      local found = false
      for _, candidate in ipairs(snapshot.tasks) do
        if candidate.id == task.parent_id then found = true break end
      end
      if not found then
        add_error(errors, "task points to missing parent: " .. tostring(task.parent_id))
      end
    end
    if task.parent_id ~= "root" and task.parent_id ~= task.group_id then
      add_skipped(skipped, "task.parent_id", 1,
        "Workbench tasks currently use collection ownership; nested Sakura task relationships are retained in the report")
    end
    if task.provider ~= "local" then
      add_warning(warnings, "task " .. task.id .. " uses Sakura provider "
        .. tostring(task.provider) .. "; provider metadata was not imported")
    end
    if task.external_id or task.url then
      add_skipped(skipped, "task.provider_metadata", 1,
        "the current Workbench task model has no external provider fields")
    end
  end

  local resources = {}
  for _, resource in ipairs(snapshot.resources) do
    if resources[resource.id] then
      add_error(errors, "duplicate Sakura terminal id: " .. resource.id)
    else
      resources[resource.id] = true
    end
    if resource.parent_id ~= "root"
        and not ids[resource.parent_id] and not tasks[resource.parent_id] then
      local found_task = false
      for _, task in ipairs(snapshot.tasks) do
        if task.id == resource.parent_id then found_task = true break end
      end
      if not found_task then
        add_error(errors, "terminal points to missing parent: " .. resource.parent_id)
      end
    end
    if resource.kind ~= "shell" then
      add_warning(warnings, "terminal " .. resource.id .. " is a Sakura "
        .. resource.kind .. " tab; it will be imported as a terminal resource")
    end
  end
end

local function page_terminal_archival(snapshot, warnings, skipped)
  local archived = {}
  local pages = snapshot.pages or {}
  local layouts = index_by_id(snapshot.layouts or {})

  local function visit(layout_id, page)
    local layout = layouts[layout_id]
    if not layout then return end
    if layout.type == "leaf" then
      if layout.terminal_id then
        if archived[layout.terminal_id] ~= nil and archived[layout.terminal_id] ~= page.archived then
          add_warning(warnings, "terminal " .. layout.terminal_id
            .. " appears in both archived and active Sakura pages")
        end
        archived[layout.terminal_id] = page.archived == true
      end
    else
      visit(layout.first_id, page)
      visit(layout.second_id, page)
    end
  end

  for _, page in ipairs(pages) do
    if page.root_layout then visit(page.root_layout, page) end
  end
  if #pages > 0 then
    add_skipped(skipped, "pages", #pages,
      "Sakura pages are client layout/session state, not Workbench domain entities")
  end
  if #(snapshot.layouts or {}) > 0 then
    add_skipped(skipped, "layouts", #snapshot.layouts,
      "GTK/VTE layout geometry is not imported into Workbench")
  end
  return archived
end

local function validate_pages_and_layouts(snapshot, errors)
  local pages = {}
  local layouts = {}
  local terminals = {}
  for _, resource in ipairs(snapshot.resources or {}) do
    terminals[resource.id] = true
  end
  for _, page in ipairs(snapshot.pages or {}) do
    if not page.id or page.id == "" or pages[page.id] then
      add_error(errors, "invalid or duplicate Sakura page id: " .. tostring(page.id))
    else
      pages[page.id] = page
    end
  end
  for _, layout in ipairs(snapshot.layouts or {}) do
    if not layout.id or layout.id == "" or layouts[layout.id] then
      add_error(errors, "invalid or duplicate Sakura layout id: " .. tostring(layout.id))
    else
      layouts[layout.id] = layout
    end
  end

  for _, page in ipairs(snapshot.pages or {}) do
    if page.root_layout_id then
      local root = layouts[page.root_layout_id]
      if not root then
        add_error(errors, "page points to missing root layout: " .. page.root_layout_id)
      end
    end
  end

  for _, layout in ipairs(snapshot.layouts or {}) do
    if layout.page_id and not pages[layout.page_id] then
      add_error(errors, "layout points to missing page: " .. layout.page_id)
    end
    if layout.type ~= "leaf" and layout.type ~= "split" then
      add_error(errors, "unsupported Sakura layout type: " .. tostring(layout.type))
    elseif layout.type == "split" then
      if not layout.first_id or not layouts[layout.first_id] then
        add_error(errors, "split layout points to missing first child: " .. tostring(layout.id))
      end
      if not layout.second_id or not layouts[layout.second_id] then
        add_error(errors, "split layout points to missing second child: " .. tostring(layout.id))
      end
    elseif layout.terminal_id and not terminals[layout.terminal_id] then
      add_error(errors, "layout points to missing terminal: " .. layout.terminal_id)
    end
  end

  local function visit(layout_id, page_id, state, depth)
    if not layout_id then return end
    if depth > 32 then
      add_error(errors, "Sakura layout nesting exceeds the supported depth")
      return
    end
    if state[layout_id] == "visiting" then
      add_error(errors, "cycle in Sakura layout tree at: " .. layout_id)
      return
    end
    if state[layout_id] == "visited" then return end
    local layout = layouts[layout_id]
    if not layout then return end
    if layout.page_id and layout.page_id ~= page_id then
      add_error(errors, "layout belongs to a different page: " .. layout_id)
      return
    end
    state[layout_id] = "visiting"
    if layout.type == "split" then
      visit(layout.first_id, page_id, state, depth + 1)
      visit(layout.second_id, page_id, state, depth + 1)
    end
    state[layout_id] = "visited"
  end

  for _, page in ipairs(snapshot.pages or {}) do
    if page.root_layout_id then
      visit(page.root_layout_id, page.id, {}, 0)
    end
  end
end

function Importer.parse(data)
  local sections, message = parse_key_file(data)
  if not sections then return nil, message end
  local session = sections.Session
  if not session then return nil, "Sakura session is missing the Session section" end

  local version, version_error = number(session.version, "Session.version")
  if not version then return nil, version_error end
  local snapshot = {
    version = version,
    workspace_id = optional(session, "workspace_id"),
    root_directory = optional(session, "root_directory"),
    groups = {},
    tasks = {},
    pages = {},
    layouts = {},
    terminals = {},
    sections = sections,
  }

  local counts = {
    { key = "group_count", name = "Group", target = snapshot.groups },
    { key = "task_count", name = "Task", target = snapshot.tasks },
    { key = "page_count", name = "Page", target = snapshot.pages },
    { key = "layout_count", name = "Layout", target = snapshot.layouts },
    { key = "terminal_count", name = "Terminal", target = snapshot.terminals },
  }
  for _, descriptor in ipairs(counts) do
    local count, count_error = number(session[descriptor.key],
      "Session." .. descriptor.key, 0)
    if not count then return nil, count_error end
    if count < 0 then return nil, "Session." .. descriptor.key .. " cannot be negative" end
    for index = 0, count - 1 do
      local values, section_error = section(sections, descriptor.name, index)
      if not values then return nil, section_error end
      descriptor.target[#descriptor.target + 1] = values
    end
  end

  return snapshot
end

function Importer.load(path)
  local file, message = io.open(path, "rb")
  if not file then return nil, "unable to read Sakura session: " .. tostring(message) end
  local data = file:read("*a")
  file:close()
  return Importer.parse(data)
end

function Importer.convert(source, options)
  options = options or {}
  local errors, warnings, skipped = {}, {}, {}
  local result = {
    format = "sakura-session",
    version = source.version,
    source_workspace_id = source.workspace_id,
    collections = {},
    tasks = {},
    resources = {},
    warnings = warnings,
    skipped = skipped,
    errors = errors,
    source = {
      workspace_id = source.workspace_id,
      root_directory = source.root_directory,
      pages = #source.pages,
      layouts = #source.layouts,
    },
  }

  for index, value in ipairs(source.groups) do
    local id, id_error = required(value, "id", "Group" .. tostring(index) .. ".id")
    if not id then add_error(errors, id_error) end
    local order, order_error = number(value.order, "Group" .. tostring(index) .. ".order", index)
    if not order then add_error(errors, order_error) end
    local archived, archived_error = boolean(value.archived,
      "Group" .. tostring(index) .. ".archived", false)
    if archived == nil then add_error(errors, archived_error) end
    result.collections[#result.collections + 1] = {
      id = id,
      parent_id = optional(value, "parent") or "root",
      title = optional(value, "title") or (id and "Sakura collection " .. id or ""),
      order = order or index,
      archived = archived == true,
      directory = optional(value, "directory"),
    }
  end

  for index, value in ipairs(source.tasks) do
    local id, id_error = required(value, "id", "Task" .. tostring(index) .. ".id")
    if not id then add_error(errors, id_error) end
    local status_number, status_error = number(value.status,
      "Task" .. tostring(index) .. ".status", 0)
    if not status_number then add_error(errors, status_error) end
    local order, order_error = number(value.order, "Task" .. tostring(index) .. ".order", index)
    if not order then add_error(errors, order_error) end
    local archived, archived_error = boolean(value.archived,
      "Task" .. tostring(index) .. ".archived", false)
    if archived == nil then add_error(errors, archived_error) end
    result.tasks[#result.tasks + 1] = {
      id = id,
      parent_id = optional(value, "parent") or "root",
      group_id = optional(value, "group") or "root",
      collection_id = optional(value, "group") or nil,
      title = optional(value, "title") or (id and "Sakura task " .. id or ""),
      provider = optional(value, "provider") or "local",
      external_id = optional(value, "external_id"),
      url = optional(value, "url"),
      status = map_task_status(status_number or 0),
      order = order or index,
      archived = archived == true,
    }
  end

  for index, value in ipairs(source.pages) do
    local id = optional(value, "id")
    if not id then add_error(errors, "Page" .. tostring(index) .. ".id is required") end
    result.pages = result.pages or {}
    result.pages[#result.pages + 1] = {
      id = id,
      archived = value.archived == "true" or value.archived == "1",
      root_layout_id = optional(value, "root_layout"),
    }
  end

  for index, value in ipairs(source.layouts) do
    local id = optional(value, "id")
    if not id then add_error(errors, "Layout" .. tostring(index) .. ".id is required") end
    result.layouts = result.layouts or {}
    result.layouts[#result.layouts + 1] = {
      id = id,
      page_id = optional(value, "page"),
      type = optional(value, "type") or "leaf",
      first_id = optional(value, "first"),
      second_id = optional(value, "second"),
      terminal_id = optional(value, "terminal_id"),
    }
  end

  for index, value in ipairs(source.terminals) do
    local id = optional(value, "terminal_id")
    if not id then
      add_warning(warnings, "Terminal" .. tostring(index)
        .. " has no terminal_id and was skipped")
    else
      result.resources[#result.resources + 1] = {
        id = id,
        parent_id = optional(value, "parent") or "root",
        cwd = optional(value, "cwd"),
        title = optional(value, "title"),
        kind = map_terminal_kind(optional(value, "kind")),
        original_kind = optional(value, "kind") or "shell",
        tool = optional(value, "tool"),
        tool_target = optional(value, "tool_target"),
        codex_session_id = optional(value, "codex_session_id"),
        codex_session_name = optional(value, "codex_session_name"),
        codex_reasoning_effort = optional(value, "codex_reasoning_effort"),
        original_status = tonumber(value.status),
        order = index,
      }
    end
  end

  validate_pages_and_layouts(result, errors)
  validate_records(result, errors, warnings, skipped)
  sort_collections(result.collections)
  local collection_by_id = index_by_id(result.collections)
  local task_by_id = index_by_id(result.tasks)
  local terminal_archived = page_terminal_archival(result, warnings, skipped)

  for _, task in ipairs(result.tasks) do
    if task.collection_id == "root" or not collection_by_id[task.collection_id] then
      task.collection_id = nil
    end
  end
  for _, resource in ipairs(result.resources) do
    local config = {
      cwd = resource.cwd,
      sakura_parent_id = resource.parent_id,
      sakura_kind = resource.original_kind,
      sakura_status = resource.original_status,
      tool = resource.tool,
      tool_target = resource.tool_target,
      codex_session_id = resource.codex_session_id,
      codex_session_name = resource.codex_session_name,
      codex_reasoning_effort = resource.codex_reasoning_effort,
    }
    local compact_config = {}
    for key, value in pairs(config) do
      if value ~= nil and value ~= "" then compact_config[key] = value end
    end
    resource.config = compact_config
    resource.collection_id = collection_by_id[resource.parent_id] and resource.parent_id
      or (task_by_id[resource.parent_id] and task_by_id[resource.parent_id].collection_id)
      or nil
    resource.title = resource.title or ("Sakura terminal " .. resource.id)
    resource.archived = terminal_archived[resource.id] == true
    resource.status = "stopped"
  end

  if source.root_directory then
    add_skipped(skipped, "Session.root_directory", 1,
      "Workbench does not impose a workspace working directory")
  end
  if #source.pages > 0 then
    add_skipped(skipped, "Session.selected_page_id", 1,
      "active page selection belongs to the Pragtical client layout")
  end
  result.counts = {
    collections = #result.collections,
    tasks = #result.tasks,
    resources = #result.resources,
    pages = #source.pages,
    layouts = #source.layouts,
  }
  result.valid = #errors == 0
  return result
end

local function copy_file(source_path, destination_path)
  local source, message = io.open(source_path, "rb")
  if not source then return nil, message end
  local data = source:read("*a")
  source:close()
  local destination, open_message = io.open(destination_path, "wb")
  if not destination then return nil, open_message end
  local ok, write_message = destination:write(data)
  destination:close()
  if not ok then return nil, write_message end
  return true
end

local function target_conflicts(plan, snapshot)
  local conflicts = {}
  local function check(records, existing, kind)
    local ids = {}
    for _, record in ipairs(existing or {}) do ids[record.id] = true end
    for _, record in ipairs(records) do
      if ids[record.id] then
        conflicts[#conflicts + 1] = kind .. " already exists: " .. record.id
      end
    end
  end
  check(plan.collections, snapshot.collections, "collection")
  check(plan.tasks, snapshot.tasks, "task")
  check(plan.resources, snapshot.resources, "resource")
  return conflicts
end

local function commands(plan, workspace_id, revision, options)
  options = options or {}
  local result = {}
  local function add(command, key, id)
    command.workspace_id = workspace_id
    command.expected_revision = revision + #result
    command.operation_id = "sakura-import:" .. key .. ":" .. tostring(id)
    result[#result + 1] = command
  end
  if options.rename_workspace and options.workspace_name then
    add({ type = "workspace.rename", name = options.workspace_name }, "workspace", workspace_id)
  end
  for _, collection in ipairs(plan.collections) do
    add({
      type = "collection.create",
      id = collection.id,
      title = collection.title,
      parent_id = collection.parent_id,
      order = collection.order,
      archived = collection.archived,
    }, "collection", collection.id)
  end
  for _, task in ipairs(plan.tasks) do
    add({
      type = "task.create",
      id = task.id,
      title = task.title,
      collection_id = task.collection_id,
      status = task.status,
      order = task.order,
      archived = task.archived,
    }, "task", task.id)
  end
  for _, resource in ipairs(plan.resources) do
    add({
      type = "resource.create",
      id = resource.id,
      kind = "terminal",
      provider = "builtin.shell",
      title = resource.title,
      collection_id = resource.collection_id,
      config = resource.config,
      status = resource.status,
      order = resource.order,
      archived = resource.archived,
    }, "resource", resource.id)
  end
  return result
end

function Importer.preview(path, options)
  local source, message = Importer.load(path)
  if not source then return nil, message end
  return Importer.convert(source, options)
end

local function prepare_import(client, path, options)
  options = options or {}
  local plan, message = Importer.preview(path, options)
  if not plan then return nil, message end
  plan.dry_run = options.dry_run == true
  if not plan.valid then return plan end

  local current = client:snapshot()
  local conflicts = target_conflicts(plan, current)
  if #conflicts > 0 then
    for _, conflict in ipairs(conflicts) do add_error(plan.errors, conflict) end
    plan.valid = false
    return plan
  end
  plan.commands = commands(plan, current.workspace_id, current.revision, options)
  if plan.dry_run then return plan end

  local backup_path = options.backup_path or (path .. ".bak")
  if not options.overwrite_backup then
    local existing = io.open(backup_path, "rb")
    if existing then
      existing:close()
      add_error(plan.errors, "backup already exists: " .. backup_path)
      plan.valid = false
      return plan
    end
  end
  local backed_up, backup_message = copy_file(path, backup_path)
  if not backed_up then
    add_error(plan.errors, "unable to create Sakura backup: " .. tostring(backup_message))
    plan.valid = false
    return plan
  end
  plan.backup_path = backup_path
  return plan
end

local function finish_import(client, plan, batch_result)
  plan.results = batch_result.results or {}
  if batch_result.code ~= "ok" then
    local failed_command = plan.commands[#plan.results] or plan.commands[1]
    add_error(plan.errors, "import stopped at " .. tostring(failed_command.type) .. ": "
      .. tostring(batch_result.message or batch_result.code))
    plan.partial = false
    plan.valid = false
    return plan
  end

  local final_snapshot = client:snapshot()
  plan.final_revision = final_snapshot.revision
  plan.imported = {
    collections = 0,
    tasks = 0,
    resources = 0,
  }
  local function count_imported(records, existing)
    local ids = {}
    for _, record in ipairs(existing or {}) do ids[record.id] = true end
    local count = 0
    for _, record in ipairs(records) do if ids[record.id] then count = count + 1 end end
    return count
  end
  plan.imported.collections = count_imported(plan.collections, final_snapshot.collections)
  plan.imported.tasks = count_imported(plan.tasks, final_snapshot.tasks)
  plan.imported.resources = count_imported(plan.resources, final_snapshot.resources)
  plan.valid = plan.imported.collections == #plan.collections
    and plan.imported.tasks == #plan.tasks
    and plan.imported.resources == #plan.resources
  if not plan.valid then
    add_error(plan.errors, "final Workbench snapshot did not contain every imported record")
  end
  return plan
end

function Importer.import_file(client, path, options)
  local plan, message = prepare_import(client, path, options)
  if not plan then return nil, message end
  if plan.dry_run then return plan end
  return finish_import(client, plan, client:execute_batch(plan.commands))
end

function Importer.import_file_async(client, path, callback, options)
  if type(callback) ~= "function" then
    return nil, "Sakura import callback must be a function"
  end
  local plan, message = prepare_import(client, path, options)
  if not plan then return nil, message end
  if plan.dry_run then
    callback(plan)
    return true
  end

  local request, queue_message = client:execute_batch_async(plan.commands,
    function(batch_result, error_result, completed_request)
      if error_result then
        plan.valid = false
        add_error(plan.errors, "import failed: " .. tostring(
          error_result.message or error_result.code))
        callback(plan, error_result, completed_request)
        return
      end
      callback(finish_import(client, plan, batch_result), nil, completed_request)
    end, {})
  if not request then return nil, queue_message end
  return request
end

Importer._parse_key_file = parse_key_file

return Importer
