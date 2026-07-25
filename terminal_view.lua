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
  TerminalView.super.new(self, options.terminal_options or {})
  self.client = assert(options.client, "Workbench terminal client is required")
  self.resource = options.resource or {}
  self.terminal_id = assert(options.terminal_id or self.resource.id,
    "Workbench terminal ID is required")
  self.runtime_state = Runtime.get(self.client, self.terminal_id) or {
    session = nil,
    view = self
  }

  local session = self.runtime_state.session
  if session then
    local status = session:status()
    if status == "closed" or status == "exited" or status == "error" then
      session = nil
      self.runtime_state.session = nil
    end
  end
  self.session = session or assert(self.client:terminal_session(self.terminal_id, {
    columns = self.columns,
    rows = self.lines,
    shell = self.options.shell,
    args = self.options.arguments,
    cwd = self.options.cwd,
    environment = self.options.environment,
    term = self.options.term,
    scrollback_limit = self.options.scrollback_limit,
  }))
  self.emulator = self.session.emulator
  self.terminal = self.emulator
  self.runtime_state.session = self.session
  self.runtime_state.view = self
  Runtime.set(self.client, self.terminal_id, self.runtime_state)
end

function WorkbenchTerminalView:get_name()
  return self.resource.title or self.terminal_id or TerminalView.get_name(self)
end

function WorkbenchTerminalView:set_status(status)
  if self.runtime_state.status == status then
    return true
  end
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
  TerminalView.spawn(self)
  self.runtime_state.view = self
  if self.runtime_state.status ~= "running" then
    self:set_status("running")
  end
end

function WorkbenchTerminalView:detach_runtime()
  if not self.session then return end
  local session = self.session
  local status = session:status()
  self.runtime_state.session = session
  self:detach_session()
  self.runtime_state.view = nil
  if status == "exited" then
    self:set_status("exited")
  end
end

function WorkbenchTerminalView:restart()
  if self.session then
    self.session:terminate { restart = true }
  end
  self.runtime_state.session = nil
  self.session = nil
  self.emulator = nil
  self.terminal = nil
  self.routine = nil
  self:update()
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
  local resource = options.resource or {}
  local terminal_id = assert(options.terminal_id or resource.id,
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
