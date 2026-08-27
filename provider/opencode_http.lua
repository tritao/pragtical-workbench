-- Small nonblocking HTTP/SSE client used by the Workbench agent's OpenCode
-- provider. The GUI already has core.http, but the agent deliberately does
-- not load the GUI core, so this module uses the native net API directly.

local json = require "core.json"
local protocol = require "core.http_protocol"

local Http = {}
local Request = {}
Request.__index = Request

local function failure(message)
  return false, { code = "provider_backend_unavailable", message = message }
end

local function decode_body(response)
  if response.body == "" or response.status == 204 then return nil end
  local content_type = protocol.header(response.headers, "content-type") or ""
  if content_type:find("json", 1, true) then
    local ok, value = pcall(json.decode, response.body)
    if not ok or value == nil then
      return nil, "OpenCode returned invalid JSON"
    end
    return value
  end
  return response.body
end

function Request.new(client, method, path, body, stream)
  local target = path:match("^https?://") and path
    or protocol.join_path(client.base_url, path)
  local parsed, message = protocol.parse_url(target)
  if not parsed then return nil, message end
  local headers = {}
  for key, value in pairs(client.headers) do headers[key] = value end
  local request = setmetatable({
    client = client,
    parsed = parsed,
    method = method,
    path = parsed.path,
    body = body,
    stream = stream,
    phase = "resolve",
    input = "",
    output = "",
    headers = headers,
    sse_parser = stream and protocol.SSE.new() or nil,
    started_at = client.clock(),
    timeout = stream and client.stream_timeout or client.timeout,
    closed = false,
  }, Request)
  return request
end

function Request:close()
  self.closed = true
  if self.connection then pcall(function() self.connection:close() end) end
  self.connection = nil
end

function Request:cancel(message)
  self.cancelled = true
  self.cancel_message = message or "request cancelled"
  self:close()
end

function Request:event_id()
  return self.sse_parser and self.sse_parser.last_event_id or nil
end

function Request:fail(message)
  self:close()
  return failure(message)
end

function Request:complete()
  local value, message = decode_body({
    status = self.response.status, headers = self.response.headers, body = self.output,
  })
  if message then return self:fail(message) end
  self:close()
  return true, value, self.response
end

function Request:poll()
  if self.closed then
    return false, { code = self.cancelled and "provider_request_cancelled"
      or "provider_backend_unavailable", message = self.cancel_message or "request is closed" }
  end
  if self.timeout and self.client.clock() - self.started_at >= self.timeout then
    return self:fail("OpenCode request timed out")
  end
  local net = self.client.net
  if not net then return self:fail("agent networking support is unavailable") end

  for _ = 1, 8 do
    if self.timeout and self.client.clock() - self.started_at >= self.timeout then
      return self:fail("OpenCode request timed out")
    end
    if self.phase == "resolve" then
      local address, message = net.resolve_address(self.parsed.host)
      if not address then return self:fail(message or "failed to resolve OpenCode server") end
      self.address = address
      self.phase = "resolving"
    elseif self.phase == "resolving" then
      local status, message = self.address:get_status()
      if status == "failure" then return self:fail(message or "failed to resolve OpenCode server") end
      if status ~= "success" then return nil end
      local connection, open_message = net.open_tcp(self.address, self.parsed.port,
        self.parsed.protocol == "https")
      if not connection then return self:fail(open_message or "failed to connect to OpenCode") end
      self.connection = connection
      self.phase = "connecting"
    elseif self.phase == "connecting" then
      local status, message = self.connection:get_status()
      if status == "failure" then return self:fail(message or "failed to connect to OpenCode") end
      if status ~= "success" then return nil end
      self.input = protocol.build_request(self.method, self.path, self.parsed.host,
        self.parsed.port, self.parsed.protocol, self.headers, self.body,
        "Pragtical-Workbench", self.stream and "keep-alive" or "close")
      self.input_offset = 1
      self.phase = "writing"
    elseif self.phase == "writing" then
      local remaining = self.input:sub(self.input_offset)
      local written, message = self.connection:write(remaining)
      if written == nil then return self:fail(message or "failed to write OpenCode request") end
      if written > 0 then self.input_offset = self.input_offset + written end
      if self.input_offset > #self.input then self.phase = "draining" end
      if written == 0 then return nil end
    elseif self.phase == "draining" then
      local pending, message = self.connection:get_pending_writes()
      if pending == nil then return self:fail(message or "failed to flush OpenCode request") end
      if pending > 0 then return nil end
      self.phase = "headers"
    elseif self.phase == "headers" then
      local chunk, message = self.connection:read(16 * 1024)
      if not chunk then return self:fail(message or "failed to read OpenCode response") end
      if #chunk == 0 then return nil end
      self.output = self.output .. chunk
      local response, parse_message = protocol.parse_headers(self.output)
      if not response then
        if parse_message then return self:fail(parse_message) end
        if #self.output > 128 * 1024 then
          return self:fail("OpenCode response headers are too large")
        end
        return nil
      end
      self.response = response
      self.output = response.body
      if response.status < 200 or response.status >= 300 then
        return self:fail("OpenCode HTTP request failed with status " .. tostring(response.status))
      end
      if self.stream then
        self.chunked = protocol.header(response.headers, "transfer-encoding") == "chunked"
        self.chunk_state = self.chunked and {} or nil
        if self.chunked then
          local remaining, decoded, done, chunk_message = protocol.consume_chunked(
            self.output, self.chunk_state)
          if chunk_message then return self:fail(chunk_message) end
          self.chunked_buffer = remaining
          self.sse_buffer = decoded
          self.stream_done = done
        else
          self.sse_buffer = self.output
        end
        self.output = ""
        self.phase = "stream"
        local events = self.sse_parser:feed(self.sse_buffer)
        self.sse_buffer = nil
        return true, events, self.response
      end
      if response.status == 204 then
        self:close()
        return true, nil, response
      end
      self.chunked = protocol.header(response.headers, "transfer-encoding") == "chunked"
      if self.chunked then
        self.chunk_state = {}
        local remaining, decoded, done, chunk_message = protocol.consume_chunked(
          self.output, self.chunk_state)
        if chunk_message then return self:fail(chunk_message) end
        self.chunked_buffer = remaining
        self.output = decoded
        if done then return self:complete() end
      end
      local length = tonumber(protocol.header(response.headers, "content-length"))
      if length and #self.output >= length then
        self.output = self.output:sub(1, length)
        local value, message = decode_body({
          status = response.status, headers = response.headers, body = self.output,
        })
        if message then return self:fail(message) end
        self:close()
        return true, value, response
      end
      self.expected_length = length
      self.phase = "body"
    elseif self.phase == "body" then
      if self.chunked then
        local chunk, read_message = self.connection:read(16 * 1024)
        if not chunk then return self:fail(read_message or "failed to read OpenCode response") end
        self.chunked_buffer = self.chunked_buffer .. chunk
        local remaining, decoded, done, chunk_message = protocol.consume_chunked(
          self.chunked_buffer, self.chunk_state)
        if chunk_message then return self:fail(chunk_message) end
        self.chunked_buffer = remaining
        self.output = self.output .. decoded
        if done then return self:complete() end
        return nil
      end
      if self.expected_length and #self.output >= self.expected_length then
        self.output = self.output:sub(1, self.expected_length)
        return self:complete()
      end
      local chunk, message = self.connection:read(16 * 1024)
      if not chunk then return self:fail(message or "failed to read OpenCode response") end
      if #chunk == 0 then return nil end
      self.output = self.output .. chunk
      if not self.expected_length then
        -- OpenCode's JSON endpoints use Content-Length. A connection-close
        -- response is still accepted when the peer has supplied a body.
        local status = self.connection:get_status()
        if status == "failure" then
          local value, decode_message = decode_body({
            status = self.response.status, headers = self.response.headers, body = self.output,
          })
          if decode_message then return self:fail(decode_message) end
          self:close()
          return true, value, self.response
        end
      end
    elseif self.phase == "stream" then
      if self.stream_done then return false, { code = "provider_backend_unavailable",
        message = "OpenCode event stream closed" } end
      local chunk, message = self.connection:read(16 * 1024)
      if not chunk then return self:fail(message or "OpenCode event stream failed") end
      if #chunk == 0 then
        local status = self.connection:get_status()
        if status == "failure" then
          return self:fail("OpenCode event stream closed")
        end
        return true, {}
      end
      if self.chunked then
        local remaining, decoded, done, chunk_message = protocol.consume_chunked(
          self.chunked_buffer .. chunk, self.chunk_state)
        if chunk_message then return self:fail(chunk_message) end
        self.chunked_buffer = remaining
        self.stream_done = done
        chunk = decoded
      end
      local events = self.sse_parser:feed(chunk)
      return true, events, self.response
    end
  end
  return nil
end

function Http.new(options)
  options = options or {}
  local loaded, net = pcall(require, "net")
  local clock = options.clock
  if not clock and type(system) == "table" and type(system.get_time) == "function" then
    clock = system.get_time
  end
  clock = clock or os.clock
  return setmetatable({
    base_url = options.base_url or "http://127.0.0.1:4096",
    headers = options.headers or {
      ["Content-Type"] = "application/json",
      ["Accept"] = "application/json",
      ["User-Agent"] = "Pragtical-Workbench",
    },
    net = options.net or (loaded and net or nil),
    clock = clock,
    timeout = options.timeout == nil and 30 or options.timeout,
    stream_timeout = options.stream_timeout,
  }, { __index = Http })
end

function Http:request(method, path, body)
  if body ~= nil then
    local ok, encoded = pcall(json.encode, body)
    if not ok then return nil, "failed to encode OpenCode request" end
    body = encoded
  end
  return Request.new(self, method, protocol.join_path(self.base_url, path), body, false)
end

function Http:stream(path, last_event_id)
  local request, message = Request.new(self, "GET", protocol.join_path(self.base_url, path), nil, true)
  if request then
    request.sse_parser = protocol.SSE.new(last_event_id)
    request.headers.Accept = "text/event-stream"
    request.headers.Connection = "keep-alive"
    request.headers["Cache-Control"] = "no-cache"
    if last_event_id then request.headers["Last-Event-ID"] = last_event_id end
  end
  return request, message
end

return Http
