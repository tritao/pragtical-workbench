local test = require "core.test"
local MessagePack = require "plugins.workbench.service.msgpack"
local Protocol = require "plugins.workbench.service.protocol"
local Validation = require "plugins.workbench.service.validation"

test.describe("Workbench protocol", function()
  test.test("round-trips deterministic control messages", function()
    local message = {
      protocol = 2,
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

  test.test("supports integer boundaries used by revisions and event cursors", function()
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

  test.test("enforces privileged command limits before transport", function()
    local valid, message = Validation.command {
      type = "runtime.input", runtime_id = "runtime-1",
      data = string.rep("x", Validation.limits.input_bytes + 1),
    }
    test.equal(valid, nil)
    test.contains(message, "maximum length")

    local ok = pcall(Protocol.encode, {
      kind = "command", request_id = "bounded-command",
      command = {
        type = "runtime.resize", runtime_id = "runtime-1",
        columns = Validation.limits.terminal_columns + 1, rows = 24,
      },
    })
    test.equal(ok, false)
  end)

  test.test("validates event cursor messages", function()
    local frame = Protocol.encode {
      kind = "subscribe",
      request_id = "subscribe-1",
      after_event_sequence = 17,
    }
    local decoded = assert(Protocol.decode(frame))
    test.equal(decoded.after_event_sequence, 17)

    local invalid = Protocol.encode {
      kind = "subscribe",
      request_id = "subscribe-2",
      after_event_sequence = 17,
    }
    local message = assert(Protocol.decode(invalid))
    message.after_event_sequence = 1.5
    local ok, error_message = pcall(Protocol.encode, message)
    test.equal(ok, false)
    test.ok(tostring(error_message):match("non%-negative integer"))
  end)

  test.test("negotiates a compatible minor protocol and rejects a major mismatch", function()
    local compatibility = assert(Protocol.compatibility {
      protocol_major = Protocol.major,
      protocol_minor = 99,
    })
    test.equal(compatibility.major, Protocol.major)
    test.equal(compatibility.minor, Protocol.minor)
    local incompatible, message = Protocol.compatibility {
      protocol_major = Protocol.major + 1,
      protocol_minor = 0,
    }
    test.equal(incompatible, nil)
    test.contains(message, "major")
  end)
end)
