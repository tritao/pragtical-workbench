local test = require "core.test"
local Client = require "plugins.workbench.client"
local Importer = require "plugins.workbench.sakura_import"

local function session_data()
  return [[
[Session]
version=8
workspace_id=legacy-workspace
group_count=2
task_count=1
page_count=1
layout_count=1
terminal_count=1

[Group0]
id=group-root
parent=root
order=0
title=Project
directory=/tmp/project
archived=false

[Group1]
id=group-child
parent=group-root
order=1
title=Nested\sproject
archived=true

[Task0]
id=task-one
parent=root
group=group-child
order=3
title=Build\sintegration
provider=local
status=4
archived=true

[Page0]
id=page-one
parent=root
title=Ignored
title_set_by_user=false
archived=false
root_layout=layout-one

[Layout0]
id=layout-one
page=page-one
type=leaf
terminal_id=terminal-one

[Terminal0]
parent=task-one
cwd=/tmp/project
terminal_id=terminal-one
kind=shell
title_set_by_user=true
title=Build\sshell
status=1
]]
end

local function temporary_session()
  local path = os.tmpname()
  local file = assert(io.open(path, "wb"))
  assert(file:write(session_data()))
  file:close()
  return path
end

local workspace_sequence = 0
local function workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "sakura-import-test-" .. tostring(workspace_sequence)
end

test.describe("Sakura Workbench importer", function()
  test.test("loads a real-world Sakura v8 session fixture", function()
    local source, message = Importer.load(
      "data/plugins/workbench/tests/fixtures/sakura-session-v8.conf")
    test.ok(source, message)
    local plan = Importer.convert(source)
    test.ok(plan.valid, table.concat(plan.errors, "\n"))
    test.equal(plan.counts.collections, 19)
    test.equal(plan.counts.tasks, 3)
    test.equal(plan.counts.resources, 4)
    test.ok(#plan.skipped > 0)
  end)

  test.test("parses and converts the persisted Sakura records", function()
    local source = assert(Importer.parse(session_data()))
    test.equal(source.workspace_id, "legacy-workspace")
    test.equal(source.groups[2].title, "Nested project")
    test.equal(source.tasks[1].status, "4")

    local plan = Importer.convert(source)
    test.ok(plan.valid)
    test.equal(plan.counts.collections, 2)
    test.equal(plan.counts.tasks, 1)
    test.equal(plan.counts.resources, 1)
    test.equal(plan.collections[1].id, "group-root")
    test.equal(plan.collections[2].parent_id, "group-root")
    test.equal(plan.tasks[1].collection_id, "group-child")
    test.equal(plan.resources[1].config.cwd, "/tmp/project")
    test.equal(plan.resources[1].collection_id, "group-child")
    test.ok(#plan.skipped >= 2)
  end)

  test.test("rejects ambiguous references and layout cycles", function()
    local source = assert(Importer.parse(session_data()))
    source.layouts[1].first_id = "layout-one"
    source.layouts[1].type = "split"
    source.layouts[1].second_id = "missing-layout"
    local plan = Importer.convert(source)
    test.ok(not plan.valid)
    test.ok(#plan.errors >= 1)
  end)

  test.test("supports dry-run without changing the source or target", function()
    local path = temporary_session()
    local file = assert(io.open(path, "rb"))
    local original = file:read("*a")
    file:close()
    local client = assert(Client.open {
      backend = "fake",
      workspace_id = workspace_id(),
    })
    local plan = assert(Importer.import_file(client, path, { dry_run = true }))
    test.ok(plan.valid)
    test.ok(plan.dry_run)
    test.equal(#client:snapshot().collections, 0)
    local unchanged = assert(io.open(path, "rb")):read("*a")
    test.equal(unchanged, original)
    client:close()
    os.remove(path)
  end)

  test.test("creates a backup and imports through Workbench commands", function()
    local path = temporary_session()
    local backup = path .. ".backup"
    local client = assert(Client.open {
      backend = "fake",
      workspace_id = workspace_id(),
    })
    local plan = assert(Importer.import_file(client, path, {
      backup_path = backup,
    }))
    test.ok(plan.valid)
    test.equal(plan.imported.collections, 2)
    test.equal(plan.imported.tasks, 1)
    test.equal(plan.imported.resources, 1)
    test.ok(io.open(backup, "rb"))
    local snapshot = client:snapshot()
    test.equal(snapshot.collections[2].title, "Nested project")
    test.equal(snapshot.tasks[1].status, "done")
    test.equal(snapshot.terminals[1].config.cwd, "/tmp/project")
    client:close()
    os.remove(path)
    os.remove(backup)
  end)
end)
