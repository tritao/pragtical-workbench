local test = require "core.test"
local Sidebar = require "plugins.workbench.sidebar"

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
end)
