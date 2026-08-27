local test = require "core.test"
local ProviderRegistry = require "plugins.workbench.provider"
local Shell = require "plugins.workbench.provider.builtin.shell"
local Service = require "plugins.workbench.service"

test.describe("Workbench providers", function()
  test.test("exposes the built-in shell contract", function()
    local registry = ProviderRegistry.default()
    local providers = registry:describe()
    test.equal(#providers, 1)
    test.equal(providers[1].id, "builtin.shell")
    test.equal(providers[1].version, 1)
    test.equal(providers[1].kinds[1], "terminal")
    test.ok(providers[1].capabilities.actions["runtime.start"])
    test.ok(providers[1].capabilities.events["runtime.output"])

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
    test.equal(service:snapshot().providers[1].id, "builtin.shell")

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
