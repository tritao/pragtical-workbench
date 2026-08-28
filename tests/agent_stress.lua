local test = require "core.test"
local Client = require "plugins.workbench.client"

local endpoint = os.getenv("WORKBENCH_AGENT_ENDPOINT")
assert(endpoint and endpoint ~= "",
  "set WORKBENCH_AGENT_ENDPOINT or run scripts/test-workbench.sh")

local stress_output_bytes = PLATFORM == "Windows" and 196608 or 2 * 1024 * 1024

local function find_runtime(snapshot, runtime_id)
  for _, runtime in ipairs(snapshot.runtimes or {}) do
    if runtime.id == runtime_id then return runtime end
  end
end

local function wait_for_subscription(client)
  local deadline = system.get_time() + 2
  while next(client.pending_requests or {}) ~= nil and system.get_time() < deadline do
    client:poll()
    if next(client.pending_requests or {}) ~= nil then system.sleep(0.01) end
  end
  test.ok(client.agent_subscribed)
  test.ok(next(client.pending_requests or {}) == nil)
end

local function runtime_config()
  if PLATFORM == "Windows" then
    return {
      shell = "cmd.exe",
      args = {
        "/S", "/C",
        "powershell.exe -NoProfile -NonInteractive -Command "
          .. "\"$bytes = [byte[]]::new(" .. tostring(stress_output_bytes) .. "); "
          .. "for ($i = 0; $i -lt $bytes.Length; $i += 4) { "
          .. "$bytes[$i] = 27; $bytes[$i + 1] = 91; "
          .. "$bytes[$i + 2] = 48; $bytes[$i + 3] = 109 }; "
          .. "[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length); "
          .. "Start-Sleep -Seconds 4\"",
      },
      max_history_bytes = 64 * 1024,
      checkpoint_interval_bytes = 64 * 1024,
      scrollback_limit = 256,
    }
  end
  return {
    shell = "/bin/sh",
    args = { "-c", "yes X | head -c 2097152; sleep 4" },
    max_history_bytes = 64 * 1024,
    checkpoint_interval_bytes = 64 * 1024,
    scrollback_limit = 256,
  }
end

local function collect_output(client, runtime_id, minimum)
  local total = 0
  local last_offset
  local deadline = system.get_time() + (PLATFORM == "Windows" and 30 or 12)
  local resize_at = 0
  while total < minimum and system.get_time() < deadline do
    local now = system.get_time()
    if now >= resize_at then
      local queued = client:resize_runtime_async(runtime_id, 100, 30)
      test.ok(queued == true, queued and tostring(queued))
      resize_at = now + 0.05
    end
    for _, event in ipairs(client:poll_runtime_events(runtime_id)) do
      if event.type == "output" then
        test.equal(event.newest_offset, event.offset + #event.data)
        if last_offset then test.equal(event.offset, last_offset) end
        last_offset = event.newest_offset
        total = total + #event.data
      end
    end
    if total < minimum then system.sleep(0.01) end
  end
  test.ok(total >= minimum,
    "received " .. tostring(total) .. " of " .. tostring(minimum) .. " output bytes")
  test.not_nil(last_offset)
  return total, last_offset
end

local function verify_replay(result, start_offset)
  local cursor = start_offset
  for _, event in ipairs(result.runtime_events or {}) do
    if event.type == "checkpoint" then
      test.ok(event.offset >= cursor)
      cursor = event.offset
    elseif event.type == "output" then
      test.equal(event.offset, cursor)
      test.equal(event.newest_offset, event.offset + #event.data)
      cursor = event.newest_offset
    end
  end
  test.ok(cursor <= result.newest_offset)
end

local function wait_for_exit(client, runtime_id)
  local deadline = system.get_time() + 8
  while system.get_time() < deadline do
    for _, event in ipairs(client:poll_runtime_events(runtime_id)) do
      if event.type == "status" and event.status == "exited" then return true end
    end
    local runtime = find_runtime(client:snapshot(), runtime_id)
    if runtime and runtime.status == "exited" then return true end
    system.sleep(0.01)
  end
  return false
end

test.describe("Workbench agent stress behavior", function()
  test.test("evicts a stalled client without blocking another writer", function()
    local stalled = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-stress-test",
    })
    stalled:on_event(function() end)
    wait_for_subscription(stalled)

    local writer = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-stress-test",
    })
    for batch_index = 1, 12 do
      local commands = {}
      for item = 1, 128 do
        commands[#commands + 1] = {
          type = "workspace.rename",
          name = "stress-workspace-" .. tostring(batch_index) .. "-" .. tostring(item),
        }
      end
      local result = writer:execute_batch(commands)
      test.equal(result.code, "ok")
    end

    local disconnected = false
    for _ = 1, 20 do
      local _, message = stalled:poll()
      if not stalled:is_open() then
        disconnected = true
        test.ok(message ~= nil)
        break
      end
      system.sleep(0.01)
    end
    test.ok(disconnected)

    local result = writer:execute {
      type = "collection.create",
      id = "stress-writer-continued",
      title = "Writer continued",
    }
    test.equal(result.code, "ok")
    test.ok(writer:is_open())
    stalled:close()
    writer:close()
  end)

  test.test("keeps output offsets contiguous across rotation and reconnect", function()
    local runtime_id = "stress-terminal"
    local first = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-stress-test",
    })
    local created = first:execute {
      type = "terminal.create",
      id = runtime_id,
      title = "High output terminal",
      cols = 80,
      rows = 24,
      config = runtime_config(),
    }
    test.equal(created.code, "ok")
    local started, start_result = first:start_runtime(runtime_id)
    test.ok(started, start_result and start_result.message)

    local total, last_offset = collect_output(first, runtime_id, stress_output_bytes)
    test.ok(total >= stress_output_bytes)
    test.ok(last_offset >= total)

    -- Reattach while the process is still alive, then let it finish before
    -- checking the replay boundary so the producer cannot rotate past the
    -- reported oldest offset between the gap response and replay.
    first:close()
    local second = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-stress-test",
    })
    local runtime = find_runtime(second:snapshot(), runtime_id)
    test.not_nil(runtime)
    test.ok(runtime.status == "running" or runtime.status == "exited")
    test.ok(wait_for_exit(second, runtime_id))

    local gap_ok, gap = second:request_runtime_output(runtime_id, 0)
    test.ok(not gap_ok)
    test.equal(gap.code, "runtime_history_gap")
    test.ok(gap.oldest_offset > 0,
      "history gap did not report a positive oldest offset: " .. tostring(gap.oldest_offset))
    local replay_ok, replay = second:request_runtime_output(runtime_id, gap.oldest_offset)
    test.ok(replay_ok, replay and replay.message)
    test.equal(replay.code, "ok")
    test.ok(replay.newest_offset >= last_offset)
    verify_replay(replay, gap.oldest_offset)

    second:close()
    local third = assert(Client.open {
      backend = "agent", endpoint = endpoint,
      workspace_id = "agent-stress-test",
    })
    local current_gap_ok, current_gap = third:request_runtime_output(runtime_id, 0)
    test.ok(not current_gap_ok)
    test.equal(current_gap.code, "runtime_history_gap")
    local current_replay_ok, current_replay = third:request_runtime_output(
      runtime_id, current_gap.oldest_offset)
    test.ok(current_replay_ok, current_replay and current_replay.message)
    verify_replay(current_replay, current_gap.oldest_offset)

    third:close()
  end)
end)
