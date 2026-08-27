local test = require "core.test"
local Client = require "plugins.workbench.client"

local workspace_sequence = 0

local function new_workspace_id()
  workspace_sequence = workspace_sequence + 1
  return "terminal-test-" .. tostring(workspace_sequence)
end

test.describe("Workbench terminal integration", function()
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
end)
