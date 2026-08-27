local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
local phase = os.getenv("WORKBENCH_FAULT_PHASE") or "trigger"
local action = os.getenv("WORKBENCH_FAULT_ACTION") or "start"
local boundary = os.getenv("WORKBENCH_FAULT_BOUNDARY") or ""
local runtime_id = os.getenv("WORKBENCH_FAULT_RUNTIME_ID") or "fault-runtime"
local operation_id = os.getenv("WORKBENCH_FAULT_OPERATION_ID")
  or "fault-" .. action .. "-" .. runtime_id

assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")

local function runtime_record(snapshot)
  for _, runtime in ipairs(snapshot.runtimes or {}) do
    if runtime.id == runtime_id then return runtime end
  end
end

local function wait_for_request(client, request)
  local deadline = system.get_time() + 3
  while not request:is_done() and system.get_time() < deadline do
    client:poll()
    if not request:is_done() then system.sleep(0.01) end
  end
  test.ok(request:is_done())
end

local function runtime_config()
  if PLATFORM == "Windows" then
    return {
      shell = "cmd.exe",
      args = {
        "/S", "/C",
        "powershell.exe -NoProfile -NonInteractive -Command Start-Sleep -Seconds 30",
      },
    }
  end
  return { shell = "/bin/sh", args = { "-c", "sleep 30" } }
end

local function create_terminal(client)
  local created = client:execute {
    type = "terminal.create",
    id = runtime_id,
    title = "Fault recovery runtime",
    cols = 80,
    rows = 24,
    config = runtime_config(),
  }
  test.equal(created.code, "ok")
end

local function trigger_start(client)
  create_terminal(client)
  local request = assert(client:execute_async {
    type = "runtime.start",
    operation_id = operation_id,
    runtime_id = runtime_id,
    resource_id = runtime_id,
  })
  wait_for_request(client, request)
  local value, error_result = request:result()
  test.is_nil(value)
  test.equal(error_result.code, "agent_disconnected")
end

local function trigger_stop(client)
  create_terminal(client)
  local started, start_result = client:start_runtime(runtime_id)
  test.ok(started, start_result and start_result.message)

  local request = assert(client:execute_async {
    type = "runtime.stop",
    operation_id = operation_id,
    runtime_id = runtime_id,
  })
  wait_for_request(client, request)
  local value, error_result = request:result()
  test.is_nil(value)
  test.equal(error_result.code, "agent_disconnected")
end

local function duplicate(client, command, first)
  local second = client:execute(command)
  test.equal(second.code, "ok")
  test.same(second, first)
  return second
end

local function recover(client)
  local snapshot = client:snapshot()
  local runtime = runtime_record(snapshot)
  test.not_nil(runtime)
  local expected_status = boundary == "after_stopped_commit" and "stopped"
    or "interrupted"
  test.equal(runtime.status, expected_status)

  if action == "start" then
    local command = {
      type = "runtime.start",
      operation_id = operation_id,
      expected_revision = snapshot.revision,
      runtime_id = runtime_id,
      resource_id = runtime_id,
    }
    local started = client:execute(command)
    test.equal(started.code, "ok")
    duplicate(client, command, started)
    if boundary == "after_running_commit" then
      test.equal(runtime_record(client:snapshot()).status, "interrupted")
    end

    local stopped = client:execute {
      type = "runtime.stop",
      operation_id = "fault-cleanup-stop-" .. runtime_id,
      runtime_id = runtime_id,
    }
    test.equal(stopped.code, "ok")
  else
    local command = {
      type = "runtime.stop",
      operation_id = operation_id,
      expected_revision = snapshot.revision,
      runtime_id = runtime_id,
    }
    local stopped = client:execute(command)
    test.equal(stopped.code, "ok")
    duplicate(client, command, stopped)
  end

  local restart_command = {
    type = "runtime.restart",
    operation_id = "fault-restart-" .. runtime_id,
    runtime_id = runtime_id,
    resource_id = runtime_id,
  }
  local restarted = client:execute(restart_command)
  test.equal(restarted.code, "ok")
  duplicate(client, restart_command, restarted)
  local stopped = client:execute {
    type = "runtime.stop",
    operation_id = "fault-final-stop-" .. runtime_id,
    runtime_id = runtime_id,
  }
  test.equal(stopped.code, "ok")
end

test.describe("Workbench agent runtime fault recovery", function()
  test.test("recovers lifecycle operations across an abrupt agent exit", function()
    local client = assert(Client.open {
      backend = "agent",
      endpoint = endpoint,
      workspace_id = "agent-fault-test",
      request_timeout = 3,
    })
    if phase == "trigger" then
      if action == "start" then trigger_start(client) else trigger_stop(client) end
    else
      recover(client)
    end
    client:close()
  end)
end)
