local test = require "core.test"
local core = require "core"
local command = require "core.command"
local Sidebar = require "plugins.workbench.sidebar"
require "plugins.workbench"

local workspace_sequence = 0

local function new_workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "ui-test-" .. tostring(workspace_sequence)
end

test.describe("Workbench sidebar", function()
  local sidebar

  test.before_each(function()
    sidebar = Sidebar {
      backend = "fake",
      workspace_id = new_workspace_id(),
    }
  end)

  test.after_each(function()
    local root = core.root_view.root_node
    for index = #Sidebar.instances, 1, -1 do
      local view = Sidebar.instances[index]
      local node = root:get_node_for_view(view)
      if node then
        node:close_view(root, view)
      else
        view:try_close(function() end)
      end
    end
    Sidebar.instance = nil
  end)

  test.test("projects command results into the tree model", function()
    local collection = sidebar:create_collection("Editor")
    test.equal(collection.code, "ok")
    test.equal(#sidebar.model.collections, 1)

    local task = sidebar:create_task("Workbench service")
    test.equal(task.code, "ok")
    test.equal(#sidebar.model.tasks, 1)

    local resource = sidebar:execute {
      type = "resource.create",
      id = "resource-ui",
      kind = "terminal",
      title = "Architecture plan",
    }
    test.equal(resource.code, "ok")
    test.equal(#sidebar.model.terminals, 1)
    test.equal(sidebar.model.revision, 3)
  end)

  test.test("restores the workspace and layout state", function()
    sidebar.model:set_expanded("collection-saved", false)
    local state = sidebar:get_state()
    local restored = Sidebar.from_state(state)

    test.equal(restored.model.workspace_id, state.workspace_id)
    test.equal(restored.selected_id, state.selected_id)
    test.equal(restored.model.expanded.collection_saved, nil)
    test.equal(restored.model.expanded["collection-saved"], false)
    test.equal(restored:get_state().backend, "fake")
  end)

  test.test("opens, toggles, and refreshes an attached sidebar", function()
    sidebar:try_close(function() end)
    local view = Sidebar {
      backend = "fake",
      workspace_id = new_workspace_id(),
    }
    local root = core.root_view.root_node
    local node = core.root_view:get_active_node_default()
    view.node = node:split("left", view, { x = true }, true)
    core.root_view:update()
    view.visible = false
    core.redraw = false

    test.ok(command.perform("workbench:open"))
    core.root_view:update()
    test.ok(view.visible)
    test.equal(core.active_view, view)
    test.ok(view.size.x > 0)
    test.ok(core.redraw)
    test.ok(command.perform("workbench:refresh"))

    test.ok(command.perform("workbench:toggle"))
    core.root_view:update()
    test.ok(not view.visible)
    test.equal(view.size.x, 0)
    test.ok(command.perform("workbench:toggle"))
    core.root_view:update()
    test.ok(view.visible)
    test.ok(view.size.x > 0)

    local attached = root:get_node_for_view(view)
    test.not_nil(attached)
  end)

  test.test("clears the singleton when the sidebar is closed", function()
    test.equal(Sidebar.instance, sidebar)
    sidebar:try_close(function() end)
    test.is_nil(Sidebar.instance)
    test.equal(#Sidebar.instances, 0)
  end)
end)
