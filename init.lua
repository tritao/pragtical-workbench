-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"

local Sidebar = require "plugins.workbench.sidebar"

config.plugins.workbench = common.merge({
  backend = "in_process",
  workspace = "default",
  storage_path = nil,
  size = 240 * SCALE
}, config.plugins.workbench)

local function get_view()
  return Sidebar.instance
end

local function open_view()
  local view = get_view()
  if view then
    view.visible = true
    core.set_active_view(view)
    return view
  end

  view = Sidebar()
  local node = core.root_view:get_active_node_default()
  view.node = node:split("left", view, { x = true }, true)
  core.set_active_view(view)
  return view
end

local function prompt(label, submit)
  core.command_view:enter(label, {
    submit = function(text)
      if text ~= "" then submit(text) end
    end
  })
end

command.add(nil, {
  ["workbench:open"] = function()
    open_view()
  end,

  ["workbench:toggle"] = function()
    local view = get_view()
    if not view then
      open_view()
    else
      view.visible = not view.visible
      if view.visible then core.set_active_view(view) end
      core.redraw = true
    end
  end,

  ["workbench:refresh"] = function()
    local view = get_view() or open_view()
    view:refresh()
  end,

  ["workbench:create-collection"] = function()
    local view = get_view() or open_view()
    prompt("Collection title", function(title) view:create_collection(title) end)
  end,

  ["workbench:create-task"] = function()
    local view = get_view() or open_view()
    prompt("Task title", function(title) view:create_task(title) end)
  end,

  ["workbench:create-terminal"] = function()
    local view = get_view() or open_view()
    prompt("Terminal title", function(title) view:create_terminal(title) end)
  end
})

return Sidebar
