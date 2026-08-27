local test = require "core.test"
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local SidebarHost = require "core.sidebar"
local Sidebar = require "plugins.workbench.sidebar"
config.plugins.workbench = { backend = "fake", startup = "never" }
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
    SidebarHost:register("workbench", sidebar)
  end)

  test.after_each(function()
    SidebarHost:show("files")
    for index = #Sidebar.instances, 1, -1 do
      local view = Sidebar.instances[index]
      view:try_close(function() end)
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
    test.equal(restored:get_state().backend, nil)
    test.equal(restored.client.backend, "fake")
  end)

  test.test("keeps lazy providers uninitialized until requested", function()
    local created = 0
    SidebarHost:register("lazy", function()
      created = created + 1
      return sidebar
    end)

    test.equal(created, 0)
    test.equal(SidebarHost:get_view("lazy"), sidebar)
    test.equal(created, 1)
    test.ok(SidebarHost:unregister("lazy"))
  end)

  test.test("does not restore a provider when startup restoration is disabled", function()
    local previous_state = SidebarHost.state
    SidebarHost:load_state({ mode = "lazy", visible = true, views = {} })
    local created = 0
    SidebarHost:register("lazy", function()
      created = created + 1
      return sidebar
    end, { restore = false })

    test.equal(created, 0)
    test.ok(SidebarHost:unregister("lazy"))
    SidebarHost:load_state(previous_state)
  end)

  test.test("opens, toggles, and refreshes an attached sidebar", function()
    local view = sidebar
    SidebarHost:show("workbench")
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

    local attached = core.root_view.root_node:get_node_for_view(view)
    test.not_nil(attached)
  end)

  test.test("clears the singleton when the sidebar is closed", function()
    test.equal(Sidebar.instance, sidebar)
    sidebar:try_close(function() end)
    test.is_nil(Sidebar.instance)
    test.equal(#Sidebar.instances, 0)
  end)

  test.test("switches Files and Workbench in one sidebar slot", function()
    SidebarHost:show("workbench")
    local slot = core.root_view.root_node:get_node_for_view(sidebar)
    test.not_nil(slot)
    test.ok(SidebarHost:is_active("workbench"))

    SidebarHost:show("files")
    test.ok(SidebarHost:is_active("files"))
    test.equal(core.root_view.root_node:get_node_for_view(sidebar), nil)
    test.equal(core.root_view.root_node:get_node_for_view(SidebarHost:get_view("files")), slot)

    SidebarHost:show("workbench")
    test.equal(core.root_view.root_node:get_node_for_view(sidebar), slot)
  end)

  test.test("adopts a legacy standalone Workbench sidebar", function()
    SidebarHost:show("files")
    local legacy = Sidebar {
      backend = "fake",
      workspace_id = new_workspace_id(),
    }
    local node = core.root_view:get_active_node_default()
    legacy.node = node:split("left", legacy, { x = true }, true)

    SidebarHost:register("workbench", legacy)
    SidebarHost:show("workbench")

    test.equal(core.root_view.root_node:get_node_for_view(legacy), SidebarHost.node)
    test.ok(SidebarHost:is_active("workbench"))
  end)
end)
