-- mod-version:3
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"

local Sidebar = require "plugins.workbench.sidebar"

config.plugins.workbench = common.merge({
  backend = "in_process",
  workspace = "default",
  storage_path = nil,
  size = 240 * SCALE
}, config.plugins.workbench)

local function get_view()
  local view = Sidebar.instance
  if not view then return nil end
  local root_node = core.root_view and core.root_view.root_node
  if root_node and root_node:get_node_for_view(view) then
    return view
  end
  if Sidebar.instance == view then
    Sidebar.instance = nil
  end
  return nil
end

local function open_view()
  local view = get_view()
  if not view then
    view = Sidebar()
    local node = core.root_view:get_active_node_default()
    view.node = node:split("left", view, { x = true }, true)
  end

  view.visible = true
  core.set_active_view(view)
  core.redraw = true
  return view
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
