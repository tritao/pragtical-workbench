local test = require "core.test"
local Client = require "plugins.workbench.client"
local Runtime = require "plugins.workbench.runtime"
local WorkbenchSession = require "plugins.workbench.terminal_session"
local WorkbenchTerminalView = require "plugins.workbench.terminal_view".class

local workspace_sequence = 0

local function new_workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "terminal-test-" .. tostring(workspace_sequence)
end

test.describe("Workbench terminal integration", function()
  test.test("decodes native ANSI colors and bold attributes", function()
    local client = {
      backend = "test",
      workspace_id = new_workspace_id(),
      terminal_session = function() return {} end,
    }
    local view = WorkbenchTerminalView {
      client = client,
      terminal_id = "terminal-styles",
    }

    local indexed, attributes = view:convert_color(10 + 1 * 256,
      "foreground", true)
    test.same(indexed, view.options.colors[9])
    test.equal(attributes, 10)

    local rgb = 3 + 0x12 * 256 + 0x34 * 65536 + 0x56 * 16777216
    local color = view:convert_color(rgb, "foreground", false)
    test.same(color, { 0x12, 0x34, 0x56, 255 })
    Runtime.remove(client, "terminal-styles")
  end)

  test.test("defers a new runtime until terminal geometry is known", function()
    local calls = 0
    local received
    local session = {}
    local client = {
      backend = "test",
      workspace_id = new_workspace_id(),
      terminal_session = function(_, _, options)
        calls = calls + 1
        received = options
        return session
      end,
    }

    local view = WorkbenchTerminalView {
      client = client,
      terminal_id = "terminal-deferred",
      terminal_options = { debug = true },
    }
    test.equal(calls, 0)

    view.columns, view.lines = 117, 38
    test.equal(view:create_session(), session)
    test.equal(calls, 1)
    test.equal(received.columns, 117)
    test.equal(received.rows, 38)
    test.equal(received.debug, true)
    Runtime.remove(client, "terminal-deferred")
  end)

  test.test("uses measured geometry for the remote display grid", function()
    local session = WorkbenchSession({ backend = "agent" }, {
      id = "terminal-remote", cols = 80, rows = 24,
    }, {
      columns = 117, rows = 38,
    })
    local columns, rows = session.emulator:size()
    test.equal(columns, 117)
    test.equal(rows, 38)
    session.emulator:close()
  end)

  test.test("owns a local PTY through the Workbench session boundary", function()
    test.skip_if(PLATFORM == "Windows", "POSIX PTY launch is required")

    local client = assert(Client.open {
      backend = "in_process",
      workspace_id = new_workspace_id(),
    })
    local created = client:execute {
      type = "terminal.create",
      id = "terminal-workbench",
      title = "Workbench shell",
      cols = 80,
      rows = 24,
      status = "starting",
      config = {
        shell = "/bin/sh",
        args = { "-c", "printf workbench-terminal-output; sleep 1" },
        cwd = "/tmp",
      },
    }
    test.equal(created.code, "ok")

    local session = assert(client:terminal_session("terminal-workbench"))
    test.equal(session:status(), "running")
    test.ok(session.capabilities.local_process)
    test.ok(session.capabilities.persistent)
    test.ok(not session.capabilities.replay)

    local output = {}
    local deadline = system.get_time() + 2
    while system.get_time() < deadline and session:status() == "running" do
      local events = session:poll_events()
      for _, event in ipairs(events) do
        if event.type == "output" then output[#output + 1] = event.data end
      end
      if table.concat(output):find("workbench-terminal-output", 1, true) then
        break
      end
      system.sleep(0.01)
    end

    test.contains(table.concat(output), "workbench-terminal-output")
    local resized = session:resize(100, 30)
    test.ok(resized ~= false)
    test.ok(session:detach())
    test.equal(session:status(), "running")
    test.ok(session:terminate())
    test.equal(session:status(), "stopped")
    test.equal(client:snapshot().terminals[1].status, "stopped")
    client:close()
  end)

  test.test("routes a local agent provider through the provider runtime contract", function()
    test.skip_if(PLATFORM == "Windows", "POSIX PTY launch is required")

    local client = assert(Client.open {
      backend = "in_process",
      workspace_id = new_workspace_id(),
    })
    local created = client:execute {
      type = "terminal.create",
      id = "terminal-codex-provider",
      title = "Codex provider",
      provider = "builtin.codex",
      cols = 80,
      rows = 24,
      status = "starting",
      config = {
        executable = "/bin/sh",
        args = { "-c", "printf codex-provider-output; sleep 1" },
      },
    }
    test.equal(created.code, "ok")

    local session = assert(client:terminal_session("terminal-codex-provider"))
    local output = {}
    local deadline = system.get_time() + 2
    while system.get_time() < deadline do
      for _, event in ipairs(session:poll_events()) do
        if event.type == "output" then output[#output + 1] = event.data end
      end
      if table.concat(output):find("codex-provider-output", 1, true) then break end
      system.sleep(0.01)
    end
    test.contains(table.concat(output), "codex-provider-output")
    test.ok(session:terminate())
    client:close()
  end)
end)
