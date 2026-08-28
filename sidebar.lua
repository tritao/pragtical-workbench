local core = require "core"
local command = require "core.command"
local config = require "core.config"
local SidebarHost = require "core.sidebar"
local style = require "core.style"
local View = require "core.view"

local Client = require "plugins.workbench.client"
local Model = require "plugins.workbench.tree_model"

---@class plugins.workbench.sidebar : core.view
local Sidebar = View:extend()
Sidebar.instances = {}
Sidebar.next_id = 0

local empty_snapshot = function(workspace_id)
  return {
    workspace_id = workspace_id or "default",
    revision = 0,
    collections = {},
    tasks = {},
    terminals = {}
  }
end

local empty_actions = {
  { label = "Open project", command = "core:open-project-folder" },
  { label = "Create task", command = "workbench:create-task" },
  { label = "New terminal", command = "workbench:create-terminal" },
}

function Sidebar:__tostring() return "Workbench" end

function Sidebar.should_open_on_startup(startup, has_saved_state)
  return startup == "always"
    or (startup == "restore" and not has_saved_state)
end

function Sidebar:try_close(do_close)
  do_close()
  for index = #Sidebar.instances, 1, -1 do
    if Sidebar.instances[index] == self then
      table.remove(Sidebar.instances, index)
    end
  end
  if Sidebar.instance == self then
    Sidebar.instance = nil
  end
  SidebarHost:unregister_view(self)
end

function Sidebar:new(options)
  options = options or {}
  Sidebar.super.new(self)
  self.name = "Workbench"
  self.type_name = "plugins.workbench.sidebar"
  self.scrollable = true
  self.visible = true
  self.target_size = options.size or config.plugins.workbench.size
  self.selected_id = options.selected_id
  self.hovered_index = nil
  self.empty_hovered_index = nil
  self.error = nil

  self.client, self.error = Client.open {
    backend = options.backend or config.plugins.workbench.backend,
    workspace = options.workspace_id or config.plugins.workbench.workspace,
    storage_path = options.storage_path or config.plugins.workbench.storage_path
  }
  local snapshot = empty_snapshot(options.workspace_id or config.plugins.workbench.workspace)
  if self.client then
    local ok, value = pcall(function() return self.client:snapshot() end)
    if ok then snapshot = value else self.error = value end
  end
  self.model = Model.new(snapshot)
  if options.expanded then
    self.model.expanded = options.expanded
    self.model:rebuild()
  end
  if self.client then
    self.client:on_event(function(event) self:on_event(event) end)
  end
  Sidebar.instances[#Sidebar.instances + 1] = self
  Sidebar.instance = self
end

function Sidebar.from_state(state)
  state = state or {}
  return Sidebar {
    workspace_id = state.workspace_id,
    selected_id = state.selected_id,
    expanded = state.expanded,
  }
end

function Sidebar:get_state()
  return {
    workspace_id = self.model.workspace_id,
    selected_id = self.selected_id,
    expanded = self.model.expanded
  }
end

function Sidebar:get_name()
  return self.name
end

function Sidebar:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  end
end

function Sidebar:on_scale_change(new_scale, prev_scale)
  self.target_size = self.target_size / prev_scale * new_scale
end

function Sidebar:on_event(event)
  if self.model:apply_event(event) then
    core.redraw = true
    return
  end
  self:refresh()
end

function Sidebar:refresh()
  if not self.client then return false end
  local ok, snapshot = pcall(function() return self.client:snapshot() end)
  if not ok then
    self.error = snapshot
    core.redraw = true
    return false
  end
  self.error = nil
  self.model:replace(snapshot)
  core.redraw = true
  return true
end

function Sidebar:execute(command)
  if not self.client then
    core.error(self.error or "Workbench client is unavailable")
    return nil
  end
  local ok, result = pcall(function() return self.client:execute(command) end)
  if not ok then
    core.error("Workbench command failed: %s", result)
    return nil
  end
  if result.code ~= "ok" then
    core.error("Workbench command failed: %s", result.message or result.code)
    self:refresh()
    return result
  end
  return result
end

function Sidebar:execute_async(command, callback)
  if not self.client then
    core.error(self.error or "Workbench client is unavailable")
    return nil
  end
  local function completed(result, error_result, request)
    if error_result then
      core.error("Workbench command failed: %s",
        error_result.message or error_result.code or tostring(error_result))
    elseif not result or result.code ~= "ok" then
      core.error("Workbench command failed: %s",
        result and (result.message or result.code) or "no result")
      self:refresh()
    end
    if callback then callback(result, error_result, request) end
  end
  local ok, request, message = pcall(function()
    return self.client:execute_async(command, completed)
  end)
  if not ok then
    core.error("Workbench command failed: %s", request)
    return nil, request
  end
  if not request then
    core.error("Workbench command failed: %s",
      message and (message.message or message.code) or "unable to queue command")
    return nil, message
  end
  return request
end

function Sidebar:create_collection(title)
  Sidebar.next_id = Sidebar.next_id + 1
  return self:execute {
    type = "collection.create",
    id = "collection-" .. tostring(math.floor(system.get_time() * 1000000))
      .. "-" .. tostring(Sidebar.next_id),
    title = title
  }
end

function Sidebar:create_collection_async(title, callback)
  Sidebar.next_id = Sidebar.next_id + 1
  return self:execute_async({
    type = "collection.create",
    id = "collection-" .. tostring(math.floor(system.get_time() * 1000000))
      .. "-" .. tostring(Sidebar.next_id),
    title = title
  }, callback)
end

function Sidebar:create_task(title)
  Sidebar.next_id = Sidebar.next_id + 1
  return self:execute {
    type = "task.create",
    id = "task-" .. tostring(math.floor(system.get_time() * 1000000))
      .. "-" .. tostring(Sidebar.next_id),
    title = title
  }
end

function Sidebar:create_task_async(title, callback)
  Sidebar.next_id = Sidebar.next_id + 1
  return self:execute_async({
    type = "task.create",
    id = "task-" .. tostring(math.floor(system.get_time() * 1000000))
      .. "-" .. tostring(Sidebar.next_id),
    title = title
  }, callback)
end

function Sidebar:open_terminal(terminal)
  if not self.client or not terminal then return nil end
  local ok, terminal_view = pcall(require, "plugins.workbench.terminal_view")
  if not ok then
    core.error("Workbench terminal support is unavailable: %s", terminal_view)
    return nil
  end
  local view, err = pcall(function()
    return terminal_view.open {
      client = self.client,
      resource = terminal,
      terminal_id = terminal.id
    }
  end)
  if not view then
    core.error("Could not open Workbench terminal: %s", err)
    return nil
  end
  return err
end

function Sidebar:create_terminal(title, provider)
  Sidebar.next_id = Sidebar.next_id + 1
  local collection_id
  local selected = self.selected_id and self.model.collection_by_id[self.selected_id]
  if selected then collection_id = selected.id end
  local id = "terminal-" .. tostring(math.floor(system.get_time() * 1000000))
    .. "-" .. tostring(Sidebar.next_id)
  local command = {
    type = "terminal.create",
    operation_id = id .. "-create",
    id = id,
    collection_id = collection_id,
    title = title,
    cols = 80,
    rows = 24,
    status = "starting",
  }
  if provider then command.provider = provider end
  local result = self:execute(command)
  if not result or result.code ~= "ok" then return result end
  local snapshot = self.client:snapshot()
  for _, terminal in ipairs(snapshot.terminals or {}) do
    if terminal.id == id then
      self.model:replace(snapshot)
      return self:open_terminal(terminal)
    end
  end
  return nil
end

function Sidebar:create_terminal_async(title, provider, callback)
  if type(provider) == "function" then
    callback = provider
    provider = nil
  end
  Sidebar.next_id = Sidebar.next_id + 1
  local collection_id
  local selected = self.selected_id and self.model.collection_by_id[self.selected_id]
  if selected then collection_id = selected.id end
  local id = "terminal-" .. tostring(math.floor(system.get_time() * 1000000))
    .. "-" .. tostring(Sidebar.next_id)
  local command = {
    type = "terminal.create",
    operation_id = id .. "-create",
    id = id,
    collection_id = collection_id,
    title = title,
    cols = 80,
    rows = 24,
    status = "starting",
  }
  if provider then command.provider = provider end
  return self:execute_async(command, function(result, error_result, request)
    if error_result or not result or result.code ~= "ok" then
      if callback then callback(result, error_result, request) end
      return
    end
    local snapshot = self.client:snapshot()
    self.model:replace(snapshot)
    for _, terminal in ipairs(snapshot.terminals or {}) do
      if terminal.id == id then
        local view = self:open_terminal(terminal)
        if callback then callback(result, nil, request, view) end
        return
      end
    end
    if callback then callback(nil, {
      code = "not_found", message = "created Workbench terminal was not returned"
    }, request) end
  end)
end

function Sidebar:get_item_height()
  return style.font:get_height() + style.padding.y
end

function Sidebar:is_empty()
  return #self.model.collections == 0
    and #self.model.tasks == 0
    and #self.model.terminals == 0
end

function Sidebar:get_empty_actions()
  return empty_actions
end

function Sidebar:activate_empty_action(index)
  local action = empty_actions[index]
  if not action then return false end
  return command.perform(action.command)
end

function Sidebar:get_scrollable_size()
  local content_height = #self.model.rows * self:get_item_height()
  if self:is_empty() then
    content_height = self:get_item_height() * (#empty_actions + 1)
  end
  return style.padding.y + content_height
end

function Sidebar:row_at(x, y)
  if self:is_empty()
    or x < self.position.x
    or x > self.position.x + self.size.x then
    return nil
  end
  local h = self:get_item_height()
  local index = math.floor((y - self.position.y + self.scroll.y) / h) + 1
  if index < 1 or index > #self.model.rows then return nil end
  return index, self.model:get_row(index)
end

function Sidebar:empty_action_at(x, y)
  if not self:is_empty()
    or x < self.position.x
    or x > self.position.x + self.size.x then
    return nil
  end
  local start_y = self.position.y + style.padding.y + self:get_item_height()
  local index = math.floor((y - start_y) / self:get_item_height()) + 1
  if index < 1 or index > #empty_actions then return nil end
  return index
end

function Sidebar:on_mouse_moved(x, y, dx, dy)
  local processed = Sidebar.super.on_mouse_moved(self, x, y, dx, dy)
  local empty_index = self:empty_action_at(x, y)
  local index = self:row_at(x, y)
  if self.empty_hovered_index ~= empty_index then
    self.empty_hovered_index = empty_index
    core.redraw = true
  end
  if self.hovered_index ~= index then
    self.hovered_index = index
    core.redraw = true
  end
  return processed or index ~= nil or empty_index ~= nil
end

function Sidebar:on_mouse_left()
  Sidebar.super.on_mouse_left(self)
  self.hovered_index = nil
  self.empty_hovered_index = nil
end

function Sidebar:on_mouse_wheel(y, x)
  if not self.scrollable then return end
  self.scroll.to.y = self.scroll.to.y - y * self:get_item_height() * 3
  self:clamp_scroll_position()
  return true
end

function Sidebar:on_mouse_pressed(button, x, y, clicks)
  local processed = Sidebar.super.on_mouse_pressed(self, button, x, y, clicks)
  if processed or button ~= "left" then return processed end
  local empty_index = self:empty_action_at(x, y)
  if empty_index then
    self:activate_empty_action(empty_index)
    return true
  end
  local index, row = self:row_at(x, y)
  if not row then return false end
  self.selected_id = row.id
  if row.kind == "collection" and row.expandable then
    self.model:set_expanded(row.id, not row.expanded)
  elseif row.kind == "terminal" or row.kind == "runtime" then
    self:open_terminal(row.entity)
  end
  core.redraw = true
  return true
end

function Sidebar:update()
  local processed = Sidebar.super.update(self)

  if self.client then
    local ok, result = pcall(function() return self.client:poll() end)
    if not ok then
      self.error = result
    end
  end
  return processed
end

function Sidebar:draw_row(row, index, x, y, w, h)
  local active = row.id == self.selected_id
  local hovered = index == self.hovered_index
  if active then
    renderer.draw_rect(self.position.x, y, self.size.x, h, style.line_highlight)
  elseif hovered then
    local color = { table.unpack(style.line_highlight) }
    color[4] = 160
    renderer.draw_rect(self.position.x, y, self.size.x, h, color)
  end

  local indent = row.depth * style.padding.x
  local marker = "  "
  if row.expandable then
    marker = row.expanded and "▾ " or "▸ "
  elseif row.kind == "section" then
    marker = ""
  end
  local color = row.kind == "section" and style.dim or style.text
  renderer.draw_text(style.font, marker .. row.label,
    x + style.padding.x + indent, y + style.padding.y / 2, color)
end

function Sidebar:draw()
  self:draw_background(style.background2)
  local x, y = self:get_content_offset()
  local h = self:get_item_height()
  if self:is_empty() then
    local header_y = y + style.padding.y
    renderer.draw_text(style.font, "No workspace items yet", x + style.padding.x,
      header_y, style.text)
    for index, action in ipairs(empty_actions) do
      local action_y = header_y + h * index
      local hovered = index == self.empty_hovered_index
      if hovered then
        renderer.draw_rect(self.position.x, action_y, self.size.x, h,
          style.line_highlight)
      end
      renderer.draw_text(style.font, action.label, x + style.padding.x,
        action_y + style.padding.y / 2, hovered and style.text or style.dim)
    end
  end
  if not self:is_empty() then
    local top = self.position.y
    local bottom = top + self.size.y
    for index, row in ipairs(self.model.rows) do
      local row_y = y + (index - 1) * h + style.padding.y / 2
      if row_y + h >= top and row_y < bottom then
        self:draw_row(row, index, x, row_y, self.size.x, h)
      end
    end
  end
  if self.error then
    renderer.draw_text(style.font, "Workbench unavailable",
      self.position.x + style.padding.x,
      self.position.y + self.size.y - style.font:get_height() - style.padding.y,
      style.error)
  end
  self:draw_scrollbar()
end

return Sidebar
