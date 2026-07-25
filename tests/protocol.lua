local test = require "core.test"
local MessagePack = require "plugins.workbench.service.msgpack"
local Protocol = require "plugins.workbench.service.protocol"

test.describe("Workbench protocol", function()
  test.test("round-trips deterministic control messages", function()
    local message = {
      protocol = 1,
      kind = "command",
      request_id = "request-1",
      command = {
        type = "task.create",
        expected_revision = 42,
        title = "MessagePack transport",
        enabled = true,
        bytes = "\0\xff\n",
      },
    }
    local first = Protocol.encode(message)
    local second = Protocol.encode(message)
    test.equal(first, second)
    local decoded = assert(Protocol.decode(first))
    test.same(decoded, message)
  end)

  test.test("supports integer boundaries used by revisions and offsets", function()
    local value = {
      zero = 0,
      positive = 4294967295,
      negative = -2147483648,
      array = { 1, 2, 3 },
    }
    local encoded = MessagePack.encode(value)
    local decoded, position = MessagePack.decode(encoded)
    test.same(decoded, value)
    test.equal(position, #encoded + 1)
  end)

  test.test("rejects trailing protocol data", function()
    local frame = Protocol.encode { kind = "close" } .. "extra"
    local decoded, message = Protocol.decode(frame)
    test.equal(decoded, nil)
    test.ok(message:match("trailing"))
  end)

  test.test("validates command batches", function()
    local frame = Protocol.encode {
      kind = "batch",
      request_id = "batch-1",
      commands = {
        { type = "workspace.rename", name = "Imported" },
      },
    }
    local decoded = assert(Protocol.decode(frame))
    test.equal(decoded.kind, "batch")
    test.equal(decoded.commands[1].type, "workspace.rename")
  end)
end)
