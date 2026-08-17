local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")

local function collect_output(session, seconds, expected)
  local output = {}
  local deadline = system.get_time() + seconds
  while system.get_time() < deadline do
    for _, event in ipairs(session:poll_events()) do
      if event.type == "output" then output[#output + 1] = event.data end
    end
    if not expected or table.concat(output):find(expected, 1, true) then break end
    system.sleep(0.01)
  end
  return table.concat(output)
end

test.describe("Workbench agent terminal runtime", function()
  test.test("keeps a PTY alive across client reconnect and replays history", function()
    local shell, args, input
    if PLATFORM == "Windows" then
      shell = "cmd.exe"
      args = {
        "/V:ON", "/S", "/C",
        "echo agent-terminal-output & set /p line= & "
          .. "echo agent-input:!line! & "
          -- timeout is console-input aware and can consume the CR/LF sent to
          -- set /p through ConPTY. Keep the child alive without reading input.
          .. "powershell.exe -NoProfile -NonInteractive -Command "
          .. "Start-Sleep -Seconds 10",
      }
      input = "agent-input\r\n"
    else
      shell = "/bin/sh"
      args = {
        "-c",
        "printf agent-terminal-output; read line; printf agent-input:$line; sleep 10",
      }
      input = "agent-input\n"
    end

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
        shell = shell,
        args = args,
      },
    }
    test.equal(created.code, "ok")

    local session = assert(first:terminal_session("agent-terminal"))
    test.ok(session.capabilities.persistent)
    test.ok(session.capabilities.replay)
    test.ok(session:attach())
    test.contains(collect_output(session, 2, "agent-terminal-output"), "agent-terminal-output")
    test.ok(session:write(input))
    test.contains(collect_output(session, 2, "agent-input:agent-input"), "agent-input:agent-input")
    test.ok(session:detach())
    first:close()

    local second = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-terminal-test",
    })
    test.equal(second:snapshot().terminals[1].status, "running")
    local reattached = assert(second:terminal_session("agent-terminal"))
    test.ok(reattached:attach())
    test.contains(collect_output(reattached, 2, "agent-terminal-output"), "agent-terminal-output")
    test.ok(reattached:resize(100, 30))
    test.ok(reattached:terminate())
    test.equal(reattached:status(), "closed")
    second:close()
  end)
end)
