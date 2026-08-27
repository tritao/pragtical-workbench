local test = require "core.test"
local ProviderRegistry = require "plugins.workbench.provider"
local Shell = require "plugins.workbench.provider.builtin.shell"
local Service = require "plugins.workbench.service"

local function find_provider(providers, id)
  for _, provider in ipairs(providers) do
    if provider.id == id then return provider end
  end
end

test.describe("Workbench providers", function()
  test.test("exposes the built-in shell contract", function()
    local registry = ProviderRegistry.default()
    local providers = registry:describe()
    test.equal(#providers, 3)
    local shell = find_provider(providers, "builtin.shell")
    local codex = find_provider(providers, "builtin.codex")
    local opencode = find_provider(providers, "builtin.opencode")
    test.equal(shell.version, 1)
    test.equal(shell.kinds[1], "terminal")
    test.ok(shell.capabilities.actions["runtime.start"])
    test.ok(shell.capabilities.events["runtime.output"])
    test.ok(codex.capabilities.actions["runtime.start"])
    test.ok(opencode.capabilities.actions["runtime.start"])

    local resource, provider = registry:create_resource({
      title = "Shell",
      kind = "terminal",
    })
    test.equal(provider, Shell)
    test.equal(resource.provider, "builtin.shell")
    test.equal(resource.kind, "terminal")

    local spec = assert(registry:runtime_spec(resource, {}))
    test.equal(spec.command, os.getenv("SHELL") or "sh")
    local metadata = assert(registry:runtime_metadata(resource, spec))
    test.equal(metadata.provider, "builtin.shell")
    test.equal(metadata.shell, spec.command)
    test.ok(registry:allows(resource, "runtime.start"))
    test.ok(registry:validate_metadata("builtin.shell", { version = 1 }))
  end)

  test.test("builds interactive Codex and OpenCode runtime specifications", function()
    local registry = ProviderRegistry.default()
    local codex_resource = assert(registry:create_resource {
      provider = "builtin.codex",
      kind = "terminal",
      title = "Codex",
      config = { executable = "/opt/codex", model = "gpt-5" },
    })
    local codex = assert(registry:runtime_spec(codex_resource, {
      prompt = "Inspect this repository",
      sandbox = "workspace-write",
    }))
    test.equal(codex.command, "/opt/codex")
    test.equal(codex.args[1], "-m")
    test.equal(codex.args[2], "gpt-5")
    test.equal(codex.args[3], "-s")
    test.equal(codex.args[4], "workspace-write")
    test.equal(codex.args[5], "Inspect this repository")

    local canonical_codex = assert(registry:runtime_spec(codex_resource, {
      execution_policy = {
        approval = "prompt",
        sandbox = "workspace",
        permissions = { network = "prompt" },
      },
    }))
    test.equal(canonical_codex.args[1], "-m")
    test.equal(canonical_codex.args[2], "gpt-5")
    test.equal(canonical_codex.args[3], "-s")
    test.equal(canonical_codex.args[4], "workspace-write")
    test.equal(canonical_codex.args[5], "-a")
    test.equal(canonical_codex.args[6], "on-request")
    test.equal(canonical_codex.execution_policy.sandbox, "workspace")
    test.equal(canonical_codex.execution_policy.permissions.network, "prompt")

    local opencode_resource = assert(registry:create_resource {
      provider = "builtin.opencode",
      kind = "terminal",
      title = "OpenCode",
    })
    local opencode = assert(registry:runtime_spec(opencode_resource, {
      prompt = "Review this repository",
      model = "anthropic/claude-sonnet",
      auto = true,
    }))
    test.equal(opencode.command, "opencode")
    test.equal(#opencode.args, 0)
    test.equal(opencode.server_url, "http://127.0.0.1:4096")
    test.ok(opencode.manage_server)
    test.equal(opencode.model, "anthropic/claude-sonnet")
    test.equal(opencode.prompt, "Review this repository")
    test.equal(opencode.execution_policy.approval, "auto")

    local canonical_opencode = assert(registry:runtime_spec(opencode_resource, {
      execution_policy = { approval = "auto" },
    }))
    test.equal(#canonical_opencode.args, 0)
    test.equal(canonical_opencode.server_url, "http://127.0.0.1:4096")
    test.equal(canonical_opencode.execution_policy.approval, "auto")
  end)

  test.test("runs the shell through the provider lifecycle contract", function()
    local registry = ProviderRegistry.default()
    local resource = assert(registry:create_resource {
      kind = "terminal",
      title = "Lifecycle shell",
    })
    local calls = { created = 0, polled = 0, written = nil, resized = nil }
    local function new_handle()
      local handle = { closed = false, did_exit = false }
      function handle:poll()
        calls.polled = calls.polled + 1
        return "provider-output"
      end
      function handle:exited()
        if self.did_exit then return true, 7, 9 end
        return false
      end
      function handle:write(data)
        calls.written = data
        return #data
      end
      function handle:resize(columns, rows)
        calls.resized = { columns, rows }
        return true
      end
      function handle:close()
        self.closed = true
        return true
      end
      return handle
    end
    local native = {
      new = function(spec)
        calls.created = calls.created + 1
        calls.spec = spec
        return new_handle()
      end,
    }
    local context = { runtime_native = native, workspace_id = "provider-test" }

    local available = assert(registry:available(resource, context))
    test.ok(available)
    local capabilities = assert(registry:capabilities(resource, context))
    capabilities.actions["runtime.start"] = false
    test.ok(Shell.capabilities.actions["runtime.start"])

    local spec = assert(registry:runtime_spec(resource, {}))
    local runtime = assert(registry:create(resource, spec, context))
    test.equal(calls.created, 1)
    test.equal(calls.spec.command, spec.command)
    test.equal(registry:send_input(resource, runtime, "input", context), 5)
    test.equal(calls.written, "input")
    test.ok(registry:action(resource, runtime, "resize", {
      columns = 100, rows = 30,
    }, context))
    test.equal(calls.resized[1], 100)
    test.equal(calls.resized[2], 30)

    local policy_spec = assert(registry:runtime_spec(resource, {
      execution_policy = {
        sandbox = "workspace",
        permissions = { filesystem = "prompt" },
      },
    }))
    test.equal(policy_spec.execution_policy.sandbox, "workspace")
    test.equal(policy_spec.execution_policy.permissions.filesystem, "prompt")

    local status = assert(registry:refresh_status(resource, runtime, context))
    test.equal(status.status, "running")
    test.equal(status.output, "provider-output")
    runtime.did_exit = true
    status = assert(registry:refresh_status(resource, runtime, context))
    test.equal(status.status, "exited")
    test.equal(status.exit_code, 7)
    test.equal(status.signal, 9)
    test.ok(registry:stop(resource, runtime, context))
    test.ok(runtime.closed)

    local restarted = assert(registry:restart(resource, runtime, spec, context))
    test.equal(calls.created, 2)
    test.ok(registry:stop(resource, restarted, context))

    local unavailable, unavailable_message = registry:available(resource, {})
    test.ok(not unavailable)
    test.equal(unavailable_message.code, "provider_unavailable")
    local attached, attach_message = registry:attach(resource, {}, context)
    test.is_nil(attached)
    test.equal(attach_message.code, "provider_action_unsupported")
    local recovered, recover_message = registry:recover(resource, {}, context)
    test.is_nil(recovered)
    test.equal(recover_message.code, "provider_action_unsupported")
    test.ok(registry:shutdown(context))
  end)

  test.test("reports provider runtime failures and contract violations", function()
    local registry = ProviderRegistry.default()
    local resource = assert(registry:create_resource {
      provider = "builtin.shell",
      kind = "terminal",
      title = "Failing shell",
    })
    local spec = assert(registry:runtime_spec(resource, {}))
    local runtime, runtime_message = registry:start(resource, spec, {
      runtime_native = {
        new = function()
          error("backend disappeared")
        end,
      },
    })
    test.is_nil(runtime)
    test.equal(runtime_message.code, "provider_runtime_error")

    local invalid, invalid_message = registry:refresh_status(resource, {}, {})
    test.is_nil(invalid)
    test.equal(invalid_message.code, "provider_contract")

    local unavailable, unavailable_message = registry:available(resource, {
      runtime_native = {
        new = function() end,
        available = function() return false, "executable is not available" end,
      },
      command = { executable = "missing-workbench-command" },
    })
    test.ok(not unavailable)
    test.equal(unavailable_message.code, "provider_executable_unavailable")
  end)

  test.test("rejects unsupported provider operations and malformed resources", function()
    local registry = ProviderRegistry.default()
    local resource, message = registry:create_resource {
      provider = "missing.provider",
      kind = "terminal",
      title = "Unknown",
    }
    test.is_nil(resource)
    test.equal(message.code, "provider_not_found")

    local malformed, malformed_message = registry:create_resource {
      kind = "terminal",
      title = "Malformed",
      config = "not-a-table",
    }
    test.is_nil(malformed)
    test.equal(malformed_message.code, "provider_invalid_resource")

    local invalid_policy, invalid_policy_message = registry:create_resource {
      provider = "builtin.shell",
      kind = "terminal",
      title = "Invalid policy",
      config = { execution_policy = { approval = "always" } },
    }
    test.is_nil(invalid_policy)
    test.equal(invalid_policy_message.code, "provider_invalid_resource")
  end)

  test.test("service snapshots providers and validates provider metadata", function()
    local service = Service.new { workspace_id = "provider-test" }
    local resource = service:execute {
      type = "resource.create",
      operation_id = "provider-resource",
      expected_revision = 0,
      id = "provider-terminal",
      title = "Provider terminal",
    }
    test.equal(resource.code, "ok")
    test.not_nil(find_provider(service:snapshot().providers, "builtin.shell"))

    local metadata = service:execute {
      type = "provider.metadata.update",
      operation_id = "provider-metadata",
      expected_revision = 1,
      provider = { id = "builtin.shell", metadata = { version = 1 } },
    }
    test.equal(metadata.code, "ok")

    local unknown = service:execute {
      type = "provider.metadata.update",
      operation_id = "unknown-provider-metadata",
      expected_revision = 2,
      provider = { id = "missing.provider", metadata = {} },
    }
    test.equal(unknown.code, "provider_not_found")
  end)
end)
