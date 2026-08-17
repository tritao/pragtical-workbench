-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local SidebarHost = require "core.sidebar"

local Sidebar = require "plugins.workbench.sidebar"

local startup_values = {
  always = true,
  restore = true,
  never = true,
}

config.plugins.workbench = common.merge({
  backend = "in_process",
  workspace = "default",
  storage_path = nil,
  size = 240 * SCALE,
  startup = "restore",
  config_spec = {
    name = "Workbench",
    {
      label = "Startup",
      description = "Control whether Workbench opens when Pragtical starts.",
      path = "startup",
      type = "selection",
      default = "restore",
      values = {
        { "Restore previous state", "restore" },
        { "Always open Workbench", "always" },
        { "Never open automatically", "never" },
      }
    }
  }
}, config.plugins.workbench)

if not startup_values[config.plugins.workbench.startup] then
  config.plugins.workbench.startup = "restore"
end

local function get_view()
  if not SidebarHost:is_active("workbench") then return nil end
  return SidebarHost:get_view("workbench")
end

local function open_view()
  return SidebarHost:show("workbench")
end

local function prompt(label, submit)
  core.command_view:enter(label, {
    submit = function(text)
      if text ~= "" then submit(text) end
    end
  })
end

local function show_import_report(plan)
  if #plan.errors > 0 then
    core.error("Sakura import failed: %s", plan.errors[1])
    return
  end
  local counts = plan.imported or plan.counts or {}
  local message = string.format(
    "Sakura import: %d collections, %d tasks, %d terminal resources",
    counts.collections or 0, counts.tasks or 0, counts.resources or 0)
  if plan.backup_path then message = message .. " (backup: " .. plan.backup_path .. ")" end
  core.status_view:show_message("i", style.text, message)
end

local function show_import_preview(plan)
  local counts = plan.counts or {}
  local message = string.format(
    "Sakura preview: %d collections, %d tasks, %d terminal resources",
    counts.collections or 0, counts.tasks or 0, counts.resources or 0)
  if #plan.warnings > 0 then
    message = message .. string.format("; %d warnings", #plan.warnings)
  end
  if #plan.skipped > 0 then
    message = message .. string.format("; %d skipped fields", #plan.skipped)
  end
  core.status_view:show_message("i", style.text, message)
end

SidebarHost:register("workbench", function(state)
  local legacy = Sidebar.instance
  local root_node = core.root_view and core.root_view.root_node
  if legacy and root_node and root_node:get_node_for_view(legacy) then
    return legacy
  end
  return Sidebar.from_state(state)
end, { restore = config.plugins.workbench.startup ~= "never" })

local function add_toolbar_button()
  local treeview = package.loaded["plugins.treeview"]
  local toolbar = treeview and treeview.toolbar
  if not toolbar then return end
  for _, item in ipairs(toolbar.toolbar_commands or {}) do
    if item.command == "workbench:open" then return end
  end
  table.insert(toolbar.toolbar_commands, { symbol = "W", command = "workbench:open" })
end

add_toolbar_button()

local startup = config.plugins.workbench.startup
if startup == "always"
  or (startup == "restore" and not SidebarHost:has_saved_state())
then
  open_view()
end

command.add(nil, {
  ["workbench:open"] = function()
    open_view()
  end,

  ["workbench:show-files"] = function()
    SidebarHost:show("files")
  end,

  ["workbench:toggle"] = function()
    if SidebarHost:is_active("workbench") then
      SidebarHost:toggle("workbench")
    else
      open_view()
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
  end,

  ["workbench:import-sakura"] = function()
    local view = get_view() or open_view()
    if not view.client then
      core.error("Workbench client is unavailable")
      return
    end
    prompt("Sakura session file", function(path)
      local Importer = require "plugins.workbench.sakura_import"
      local ok, plan, message = pcall(function()
        return Importer.preview(path)
      end)
      if not ok then
        core.error("Sakura import failed: %s", plan)
        return
      end
      if not plan then
        core.error("Sakura import failed: %s", message or "unknown importer error")
        return
      end
      if not plan.valid then
        show_import_report(plan)
        return
      end
      show_import_preview(plan)
      prompt("Type import to confirm Sakura migration", function(answer)
        if answer:lower() ~= "import" then
          core.status_view:show_message("i", style.text, "Sakura import canceled")
          return
        end
        local import_ok, result, import_message = pcall(function()
          return Importer.import_file(view.client, path)
        end)
        if not import_ok then
          core.error("Sakura import failed: %s", result)
          return
        end
        if not result then
          core.error("Sakura import failed: %s", import_message or "unknown importer error")
          return
        end
        show_import_report(result)
        if result.valid then view:refresh() end
      end)
    end)
  end
})

return Sidebar
