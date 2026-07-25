local core = require "core"

local TerminalPlugin = require "plugins.terminal"
local TerminalView = TerminalPlugin.class
local Runtime = require "plugins.workbench.runtime"

local WorkbenchTerminalView = TerminalView:extend()
WorkbenchTerminalView.next_operation = 0

local function next_operation_id(terminal_id)
  WorkbenchTerminalView.next_operation = WorkbenchTerminalView.next_operation + 1
  return "pragtical-terminal-" .. terminal_id .. "-" ..
    tostring(WorkbenchTerminalView.next_operation)
end

function WorkbenchTerminalView:new(options)
  options = options or {}
  TerminalView.super.new(self, options.terminal_options or options)
  self.client = assert(options.client, "Workbench terminal client is required")
  self.resource = options.resource or {}
  self.terminal_id = assert(options.terminal_id or self.resource.id,
    "Workbench terminal ID is required")
  self.runtime_state = Runtime.get(self.client, self.terminal_id) or {
    terminal = nil,
    view = self
  }
  self.runtime_state.view = self
  Runtime.set(self.client, self.terminal_id, self.runtime_state)
end

function WorkbenchTerminalView:get_name()
  return self.resource.title or self.terminal_id or TerminalView.get_name(self)
end

function WorkbenchTerminalView:set_status(status)
  local ok, result = pcall(function()
    return self.client:execute {
      type = "terminal.status",
      operation_id = next_operation_id(self.terminal_id),
      terminal_id = self.terminal_id,
      status = status
    }
  end)
  if not ok or result.code ~= "ok" then
    return false, ok and (result.message or result.code) or result
  end
  self.runtime_state.status = status
  return true
end

function WorkbenchTerminalView:spawn()
  if self.runtime_state.terminal then
    self:adopt_terminal(self.runtime_state.terminal)
  else
    TerminalView.spawn(self)
    self.runtime_state.terminal = self.terminal
  end
  self.runtime_state.view = self
  self:set_status("running")
end

function WorkbenchTerminalView:detach_runtime()
  if not self.terminal then return end
  local exited = self.terminal:exited()
  self.runtime_state.terminal = self:detach_terminal()
  self.runtime_state.view = nil
  if exited == true then
    self:set_status("exited")
  end
end

function WorkbenchTerminalView:try_close(do_close)
  self:detach_runtime()
  do_close()
end

function WorkbenchTerminalView:close()
  self:detach_runtime()
  local node = core.root_view.root_node:get_node_for_view(self)
  if node then
    node:close_view(core.root_view.root_node, self)
  end
  self.terminal = nil
  self.routine = nil
end

function WorkbenchTerminalView.open(options)
  local client = assert(options.client, "Workbench terminal client is required")
  local terminal_id = assert(options.terminal_id or options.resource.id,
    "Workbench terminal ID is required")
  local state = Runtime.get(client, terminal_id)
  if state and state.view then
    core.set_active_view(state.view)
    return state.view
  end
  local view = WorkbenchTerminalView(options)
  core.root_view:get_active_node_default():add_view(view)
  return view
end

return {
  class = WorkbenchTerminalView,
  open = WorkbenchTerminalView.open
}
