local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
assert(endpoint and endpoint ~= "", "WORKBENCH_AGENT_ENDPOINT is required")

local function collect_output(session, seconds)
  local output = {}
  local deadline = system.get_time() + seconds
  while system.get_time() < deadline do
    for _, event in ipairs(session:poll_events()) do
      if event.type == "output" then output[#output + 1] = event.data end
    end
    if #output > 0 then break end
    system.sleep(0.01)
  end
  return table.concat(output)
end

test.describe("Workbench agent terminal runtime", function()
  test.test("keeps a PTY alive across client reconnect and replays history", function()
    test.skip_if(PLATFORM == "Windows", "POSIX PTY launch is required")

    local first = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-terminal-test",
    })
    local created = first:execute {
      type = "terminal.create",
      id = "agent-terminal",
      title = "Agent shell",
      cols = 80,
      rows = 24,
      status = "starting",
      config = {
        shell = "/bin/sh",
        args = { "-c", "printf agent-terminal-output; read line; printf agent-input:$line; sleep 10" },
      },
    }
    test.equal(created.code, "ok")

    local session = assert(first:terminal_session("agent-terminal"))
    test.ok(session.capabilities.persistent)
    test.ok(session.capabilities.replay)
    test.ok(session:attach())
    test.contains(collect_output(session, 2), "agent-terminal-output")
    test.ok(session:write("agent-input\n"))
    test.contains(collect_output(session, 2), "agent-input:agent-input")
    test.ok(session:detach())
    first:close()

    local second = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-terminal-test",
    })
    test.equal(second:snapshot().terminals[1].status, "running")
    local reattached = assert(second:terminal_session("agent-terminal"))
    test.ok(reattached:attach())
    test.contains(collect_output(reattached, 2), "agent-terminal-output")
    test.ok(reattached:resize(100, 30))
    test.ok(reattached:terminate())
    test.equal(reattached:status(), "closed")
    second:close()
  end)
end)
