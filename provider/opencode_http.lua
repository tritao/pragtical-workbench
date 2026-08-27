-- Small nonblocking HTTP/SSE client used by the Workbench agent's OpenCode
-- provider. The GUI already has core.http, but the agent deliberately does
-- not load the GUI core, so this module uses the native net API directly.

local json = require "core.json"

local Http = {}
local Request = {}
Request.__index = Request

local function failure(message)
  return false, { code = "provider_backend_unavailable", message = message }
end

local function parse_url(url)
  local protocol, host, port, path = url:match("^(https?)://([^/:?#]+):?(%d*)(.*)$")
  if not protocol then return nil, "OpenCode server URL is invalid" end
  port = tonumber(port) or (protocol == "https" and 443 or 80)
  path = path ~= "" and path or "/"
  return {
    protocol = protocol,
    host = host,
    port = port,
    path = path,
  }
end

local function join_path(base, path)
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  return (base:gsub("/$", "")) .. path
end

local function escape_header(value)
  return tostring(value):gsub("[\r\n]", "")
end

local function build_request(method, parsed, path, headers, body)
  local values = {}
  for key, value in pairs(headers or {}) do
    values[key:lower()] = escape_header(value)
  end
  values.host = values.host or parsed.host
  values.connection = values.connection or "close"
  if body then values["content-length"] = tostring(#body) end

  local lines = { method .. " " .. path .. " HTTP/1.1" }
  for key, value in pairs(values) do
    local name = key:gsub("(^|-)(%a)", function(prefix, first)
      return prefix .. first:upper()
    end)
    lines[#lines + 1] = name .. ": " .. value
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body or ""
  return table.concat(lines, "\r\n")
end

local function append_header(headers, key, value)
  key = key:lower()
  if headers[key] == nil then
    headers[key] = value
  elseif type(headers[key]) == "table" then
    headers[key][#headers[key] + 1] = value
  else
    headers[key] = { headers[key], value }
  end
end

local function header(headers, key)
  local value = headers[key:lower()]
  if type(value) == "table" then return value[#value] end
  return value
end

local function parse_headers(data)
  local boundary = data:find("\r\n\r\n", 1, true)
  if not boundary then return nil end
  local raw = data:sub(1, boundary - 1)
  local lines = {}
  for line in (raw .. "\r\n"):gmatch("(.-)\r\n") do lines[#lines + 1] = line end
  local status = tonumber(lines[1] and lines[1]:match("^HTTP/%d+%.%d+ (%d%d%d)"))
  if not status then return nil, "OpenCode returned an invalid HTTP response" end
  local headers = {}
  for index = 2, #lines do
    local key, value = lines[index]:match("^([^:]+):%s*(.*)$")
    if key and value then append_header(headers, key, value) end
  end
  return {
    status = status,
    headers = headers,
    body = data:sub(boundary + 4),
  }, boundary + 4
end

local function decode_body(response)
  if response.body == "" or response.status == 204 then return nil end
  local content_type = header(response.headers, "content-type") or ""
  if content_type:find("json", 1, true) then
    local ok, value = pcall(json.decode, response.body)
    if not ok or value == nil then
      return nil, "OpenCode returned invalid JSON"
    end
    return value
  end
  return response.body
end

local function parse_sse(buffer)
  local events = {}
  while true do
    local index = buffer:find("\n\n", 1, true)
    local separator_length = 2
    if not index then
      index = buffer:find("\r\n\r\n", 1, true)
      separator_length = 4
    end
    if not index then break end

    local block = buffer:sub(1, index - 1)
    buffer = buffer:sub(index + separator_length)
    local event = { data = {} }
    for line in (block .. "\n"):gmatch("(.-)\r?\n") do
      if line:sub(1, 1) ~= ":" then
        local field, value = line:match("^([^:]+):?[ ]?(.*)$")
        if field == "event" then event.event = value
        elseif field == "id" then event.id = value
        elseif field == "data" then event.data[#event.data + 1] = value end
      end
    end
    if #event.data > 0 then
      event.data = table.concat(event.data, "\n")
      events[#events + 1] = event
    end
  end
  return buffer, events
end

local function consume_chunked(buffer, state)
  local decoded = {}
  while not state.done do
    if state.awaiting_trailers then
      if buffer:sub(1, 2) == "\r\n" then
        buffer = buffer:sub(3)
        state.done = true
      else
        local trailers_end = buffer:find("\r\n\r\n", 1, true)
        if not trailers_end then return buffer, table.concat(decoded), false end
        buffer = buffer:sub(trailers_end + 4)
        state.done = true
      end
    elseif state.size == nil then
      local line_end = buffer:find("\r\n", 1, true)
      if not line_end then return buffer, table.concat(decoded), false end
      local line = buffer:sub(1, line_end - 1)
      local size_text = line:match("^%s*([0-9A-Fa-f]+)")
      local size = size_text and tonumber(size_text, 16)
      if not size then return nil, nil, nil, "invalid HTTP chunk size" end
      buffer = buffer:sub(line_end + 2)
      if size == 0 then
        if buffer:sub(1, 2) == "\r\n" then
          buffer = buffer:sub(3)
          state.done = true
        else
          state.awaiting_trailers = true
        end
      else
        state.size = size
      end
    else
      if #buffer < state.size + 2 then
        return buffer, table.concat(decoded), false
      end
      if buffer:sub(state.size + 1, state.size + 2) ~= "\r\n" then
        return nil, nil, nil, "invalid HTTP chunk terminator"
      end
      decoded[#decoded + 1] = buffer:sub(1, state.size)
      buffer = buffer:sub(state.size + 3)
      state.size = nil
    end
  end
  return buffer, table.concat(decoded), true
end

function Request.new(client, method, path, body, stream)
  local target = path:match("^https?://") and path or join_path(client.base_url, path)
  local parsed, message = parse_url(target)
  if not parsed then return nil, message end
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
    sse_buffer = "",
    closed = false,
  }, Request)
  return request
end

function Request:close()
  self.closed = true
  if self.connection then pcall(function() self.connection:close() end) end
  self.connection = nil
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
  if self.closed then return false, { code = "provider_backend_unavailable", message = "request is closed" } end
  local net = self.client.net
  if not net then return self:fail("agent networking support is unavailable") end

  for _ = 1, 8 do
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
      self.input = build_request(self.method, self.parsed, self.path,
        self.client.headers, self.body)
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
      local response, body_start = parse_headers(self.output)
      if not response then
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
        self.chunked = header(response.headers, "transfer-encoding") == "chunked"
        self.chunk_state = self.chunked and {} or nil
        if self.chunked then
          local remaining, decoded, done, chunk_message = consume_chunked(
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
        local buffer, events = parse_sse(self.sse_buffer)
        self.sse_buffer = buffer
        return true, events, self.response
      end
      if response.status == 204 then
        self:close()
        return true, nil, response
      end
      self.chunked = header(response.headers, "transfer-encoding") == "chunked"
      if self.chunked then
        self.chunk_state = {}
        local remaining, decoded, done, chunk_message = consume_chunked(
          self.output, self.chunk_state)
        if chunk_message then return self:fail(chunk_message) end
        self.chunked_buffer = remaining
        self.output = decoded
        if done then return self:complete() end
      end
      local length = tonumber(header(response.headers, "content-length"))
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
        local remaining, decoded, done, chunk_message = consume_chunked(
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
      if #chunk == 0 then return true, {} end
      if self.chunked then
        local remaining, decoded, done, chunk_message = consume_chunked(
          self.chunked_buffer .. chunk, self.chunk_state)
        if chunk_message then return self:fail(chunk_message) end
        self.chunked_buffer = remaining
        self.stream_done = done
        chunk = decoded
      end
      self.sse_buffer = self.sse_buffer .. chunk
      local buffer, events = parse_sse(self.sse_buffer)
      self.sse_buffer = buffer
      return true, events, self.response
    end
  end
  return nil
end

function Http.new(options)
  options = options or {}
  local loaded, net = pcall(require, "net")
  return setmetatable({
    base_url = options.base_url or "http://127.0.0.1:4096",
    headers = options.headers or {
      ["Content-Type"] = "application/json",
      ["Accept"] = "application/json",
      ["User-Agent"] = "Pragtical-Workbench",
    },
    net = options.net or (loaded and net or nil),
  }, { __index = Http })
end

function Http:request(method, path, body)
  if body ~= nil then
    local ok, encoded = pcall(json.encode, body)
    if not ok then return nil, "failed to encode OpenCode request" end
    body = encoded
  end
  return Request.new(self, method, join_path(self.base_url, path), body, false)
end

function Http:stream(path)
  local request, message = Request.new(self, "GET", join_path(self.base_url, path), nil, true)
  if request then
    request.client.headers.Accept = "text/event-stream"
    request.client.headers.Connection = "keep-alive"
    request.client.headers["Cache-Control"] = "no-cache"
  end
  return request, message
end

return Http
