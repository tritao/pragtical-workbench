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
      provider = "builtin.codex",
      config = {
        executable = shell,
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

  test.test("bounds history and restores a persisted emulator checkpoint", function()
    local shell, args
    if PLATFORM == "Windows" then
      shell = "cmd.exe"
      args = { "/S", "/C", "echo checkpoint-output & powershell.exe -NoProfile -NonInteractive -Command Start-Sleep -Seconds 3" }
    else
      shell = "/bin/sh"
      args = { "-c", "printf checkpoint-output; sleep 3" }
    end

    local first = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-terminal-test",
    })
    local created = first:execute {
      type = "terminal.create",
      id = "checkpoint-terminal",
      title = "Checkpoint shell",
      cols = 80,
      rows = 24,
      status = "starting",
      config = {
        shell = shell,
        args = args,
        max_history_bytes = 64,
        checkpoint_interval_bytes = 1,
      },
    }
    test.equal(created.code, "ok")
    local session = assert(first:terminal_session("checkpoint-terminal"))
    test.ok(session:attach())
    test.contains(collect_output(session, 2, "checkpoint-output"), "checkpoint-output")
    first:close()

    local second = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-terminal-test",
    })
    local reattached = assert(second:terminal_session("checkpoint-terminal"))
    local replay_ok, replay_result = reattached:request_replay(0)
    test.ok(replay_ok)
    test.ok(reattached:attach())
    local checkpoint
    local checkpoint_error
    local deadline = system.get_time() + 2
    while not checkpoint and system.get_time() < deadline do
      for _, event in ipairs(reattached:poll_events()) do
        if event.type == "checkpoint" then checkpoint = event end
        if event.type == "status" and event.status == "error" then
          checkpoint_error = event.message
        end
      end
      if not checkpoint then system.sleep(0.01) end
    end
    test.not_nil(checkpoint, "checkpoint missing (offset "
      .. tostring(replay_result and replay_result.checkpoint_offset or "unknown")
      .. ", runtime events "
      .. tostring(replay_result and #(replay_result.runtime_events or {}) or "unknown")
      .. (checkpoint_error and ", error: " .. tostring(checkpoint_error) or "")
      .. ")")
    test.ok(reattached:apply_checkpoint(checkpoint, reattached.emulator))
    test.equal(checkpoint.offset, checkpoint.newest_offset)
    test.ok(checkpoint.offset - checkpoint.oldest_offset <= 64)
    test.ok(reattached.emulator:lines())
    reattached:terminate()
    second:close()
  end)
end)
