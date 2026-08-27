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
    test.equal(opencode.args[1], "--model")
    test.equal(opencode.args[2], "anthropic/claude-sonnet")
    test.equal(opencode.args[3], "--auto")
    test.equal(opencode.args[4], "--prompt")
    test.equal(opencode.args[5], "Review this repository")
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
