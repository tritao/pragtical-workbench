local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
local executable = os.getenv("WORKBENCH_CODEX_EXECUTABLE")
assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")
assert(executable and executable ~= "",
  "set WORKBENCH_CODEX_EXECUTABLE or run scripts/test-workbench.sh")

local function collect_runtime(client, runtime_id)
  local output = {}
  local status
  local deadline = system.get_time() + 8
  while system.get_time() < deadline do
    for _, event in ipairs(client:poll_runtime_events(runtime_id)) do
      if event.type == "output" then
        output[#output + 1] = event.data
      elseif event.type == "status" then
        status = event.status
      end
    end
    if status == "exited" or status == "failed" then break end
    system.sleep(0.01)
  end
  return table.concat(output), status
end

local function find_runtime(snapshot, runtime_id)
  for _, runtime in ipairs(snapshot.runtimes or {}) do
    if runtime.id == runtime_id then return runtime end
  end
end

test.describe("Workbench live provider integration", function()
  test.test("launches the installed Codex CLI through the agent PTY", function()
    local client = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-codex-test",
    })
    local created = client:execute {
      type = "terminal.create",
      operation_id = "live-codex-resource",
      id = "live-codex",
      title = "Live Codex smoke test",
      provider = "builtin.codex",
      kind = "terminal",
      status = "stopped",
      cols = 100,
      rows = 30,
      config = {
        executable = executable,
        args = { "--help" },
      },
    }
    test.equal(created.code, "ok")

    local started, start_result = client:start_runtime("live-codex")
    test.ok(started, start_result and start_result.message)
    local output, status = collect_runtime(client, "live-codex")
    test.contains(output, "Usage: codex")
    test.equal(status, "exited")
    client:close()

    local reopened = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-codex-test",
    })
    test.equal(find_runtime(reopened:snapshot(), "live-codex").status, "exited")
    reopened:close()
  end)

  test.test("reports a missing provider executable before starting a runtime", function()
    local client = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-codex-test",
    })
    local created = client:execute {
      type = "terminal.create",
      operation_id = "missing-codex-resource",
      id = "missing-codex",
      title = "Missing Codex",
      provider = "builtin.codex",
      kind = "terminal",
      status = "stopped",
      config = { executable = "workbench-codex-does-not-exist" },
    }
    test.equal(created.code, "ok")

    local started, result = client:start_runtime("missing-codex")
    test.ok(not started)
    test.equal(result.code, "provider_executable_unavailable")
    test.is_nil(find_runtime(client:snapshot(), "missing-codex"))
    client:close()
  end)
end)
