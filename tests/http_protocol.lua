local test = require "core.test"
local HttpProtocol = require "core.http_protocol"
local Http = require "plugins.workbench.provider.opencode_http"

test.describe("shared HTTP protocol", function()
  test.test("parses URLs and builds safe requests with explicit ports", function()
    local parsed = assert(HttpProtocol.parse_url("http://example.test:4096/api"))
    test.equal(parsed.host, "example.test")
    test.equal(parsed.port, 4096)
    test.equal(parsed.path, "/api")

    local request = HttpProtocol.build_request("POST", "/api", parsed.host, parsed.port,
      parsed.protocol, { ["X-Test"] = "line\r\ninjected" }, "", "Workbench", "close")
    test.contains(request, "Host: example.test:4096")
    test.contains(request, "Content-Length: 0")
    test.ok(not request:find("\r\ninjected", 1, true))
  end)

  test.test("decodes chunked bodies one byte at a time", function()
    local encoded = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n"
    local state = {}
    local pending = ""
    local decoded = {}
    local done
    for index = 1, #encoded do
      pending = pending .. encoded:sub(index, index)
      local remaining, chunk, complete, message =
        HttpProtocol.consume_chunked(pending, state)
      test.is_nil(message)
      pending = remaining
      decoded[#decoded + 1] = chunk
      done = complete
    end
    test.equal(table.concat(decoded), "Wikipedia")
    test.ok(done)
    test.equal(pending, "")
  end)

  test.test("parses fragmented SSE fields and retains the last event ID", function()
    local parser = HttpProtocol.SSE.new()
    local input = "id: 17\nevent: message\ndata: hello\ndata: world\nretry: 250\n\n"
    local events = {}
    for index = 1, #input do
      local result = parser:feed(input:sub(index, index))
      for _, event in ipairs(result) do events[#events + 1] = event end
    end
    test.equal(#events, 1)
    test.equal(events[1].event, "message")
    test.equal(events[1].data, "hello\nworld")
    test.equal(events[1].id, "17")
    test.equal(events[1].retry, 250)
    test.equal(parser.last_event_id, "17")
  end)

  test.test("parses a response only after the complete header arrives", function()
    local response = HttpProtocol.parse_headers("HTTP/1.1 200 OK\r\nContent-Length: 2")
    test.is_nil(response)
    response = assert(HttpProtocol.parse_headers(
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
    test.equal(response.status, 200)
    test.equal(response.body, "ok")
  end)

  test.test("supports cancellation and wall-clock deadlines in the agent adapter", function()
    local now = 10
    local net = {
      resolve_address = function()
        return { get_status = function() return "pending" end }
      end,
    }
    local client = Http.new {
      base_url = "http://example.test:4096",
      net = net,
      clock = function() return now end,
      timeout = 1,
    }
    local request = assert(client:request("GET", "/health"))
    test.is_nil(request:poll())
    now = 12
    local ok, message = request:poll()
    test.equal(ok, false)
    test.contains(message.message, "timed out")

    request = assert(client:request("GET", "/health"))
    request:cancel()
    ok, message = request:poll()
    test.equal(ok, false)
    test.equal(message.code, "provider_request_cancelled")
  end)

  test.test("sends the last event ID when opening a resumed stream", function()
    local response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
      .. "Content-Length: 0\r\n\r\n"
    local connection
    local net = {}
    function net.resolve_address()
      return { get_status = function() return "success" end }
    end
    function net.open_tcp()
      connection = { chunks = { response } }
      function connection:get_status() return "success" end
      function connection:get_pending_writes() return 0 end
      function connection:write(data) self.request = data return #data end
      function connection:read() return table.remove(self.chunks) or "" end
      function connection:close() end
      return connection
    end

    local client = Http.new { base_url = "http://example.test:4096", net = net }
    local request = assert(client:stream("/event", "cursor-17"))
    for _ = 1, 100 do
      local ok = request:poll()
      if ok ~= nil then break end
    end
    test.ok(connection.request:lower():find("last-event-id: cursor-17", 1, true) ~= nil)
  end)
end)
