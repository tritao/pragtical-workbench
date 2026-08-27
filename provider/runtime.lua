local Runtime = {}

local function failure(code, message)
  return nil, { code = code, message = message }
end

local function native_module(context)
  local native = context and context.runtime_native
  if type(native) ~= "table" or type(native.new) ~= "function" then
    return failure("provider_unavailable",
      "native Workbench runtime support is unavailable")
  end
  return native
end

local function handle_method(handle, method)
  if type(handle) ~= "table" and type(handle) ~= "userdata" then
    return failure("provider_runtime_error", "provider returned no runtime handle")
  end
  if type(handle[method]) ~= "function" then
    return failure("provider_contract", "runtime handle is missing " .. method .. "()")
  end
  return true
end

function Runtime.attach(provider)
  provider.available = provider.available or function(_, context)
    local native, message = native_module(context)
    if not native then return false, message end
    local command = context and context.command
    local executable = command and (command.executable or command.command or command.shell)
    if not executable then
      local config = context and context.resource and context.resource.config
      executable = config and (config.executable or config.command or config.shell)
    end
    executable = executable or provider.executable
    if executable and type(native.available) == "function" then
      local called, available, available_message = pcall(native.available, executable)
      if not called then
        return false, {
          code = "provider_runtime_error",
          message = tostring(available),
        }
      end
      if not available then
        return false, {
          code = "provider_executable_unavailable",
          message = available_message or ("executable is not available: " .. executable),
        }
      end
    end
    return true
  end

  provider.create = provider.create or function(_, spec, context)
    local native, message = native_module(context)
    if not native then return nil, message end
    local ok, runtime = pcall(native.new, spec)
    if not ok then
      return failure("provider_runtime_error", tostring(runtime))
    end
    if not runtime then
      return failure("provider_runtime_error", "provider failed to create a runtime")
    end
    return runtime
  end

  provider.attach = provider.attach or function()
    return failure("provider_action_unsupported",
      provider.id .. " does not support attaching an external runtime")
  end

  provider.recover = provider.recover or function()
    return failure("provider_action_unsupported",
      provider.id .. " does not support recovering an external runtime")
  end

  provider.start = provider.start or function(resource, spec, context)
    return provider.create(resource, spec, context)
  end

  provider.stop = provider.stop or function(_, runtime)
    local valid, message = handle_method(runtime, "close")
    if not valid then return nil, message end
    local ok, result = pcall(function() return runtime:close() end)
    if not ok then return failure("provider_runtime_error", tostring(result)) end
    if result == false then
      return failure("provider_runtime_error", "provider failed to stop the runtime")
    end
    return true
  end

  provider.restart = provider.restart or function(resource, runtime, spec, context)
    local stopped, message = provider.stop(resource, runtime, context)
    if not stopped then return nil, message end
    return provider.start(resource, spec, context)
  end

  provider.send_input = provider.send_input or function(_, runtime, data)
    local valid, message = handle_method(runtime, "write")
    if not valid then return nil, message end
    local ok, written = pcall(function() return runtime:write(data or "") end)
    if not ok then return failure("provider_runtime_error", tostring(written)) end
    return written
  end

  provider.action = provider.action or function(_, runtime, action, parameters)
    if action ~= "resize" and action ~= "runtime.resize" then
      return failure("provider_action_unsupported",
        provider.id .. " does not support runtime action " .. tostring(action))
    end
    local valid, message = handle_method(runtime, "resize")
    if not valid then return nil, message end
    parameters = parameters or {}
    local columns = parameters.columns or parameters.cols
    local rows = parameters.rows
    local ok, result = pcall(function() return runtime:resize(columns, rows) end)
    if not ok then return failure("provider_runtime_error", tostring(result)) end
    if result == false then
      return failure("provider_runtime_error", "provider rejected runtime resize")
    end
    return true
  end

  provider.refresh_status = provider.refresh_status or function(_, runtime)
    local valid, message = handle_method(runtime, "poll")
    if not valid then return nil, message end
    valid, message = handle_method(runtime, "exited")
    if not valid then return nil, message end
    local ok, output = pcall(function() return runtime:poll() end)
    if not ok then return failure("provider_runtime_error", tostring(output)) end
    local exited_ok, exited, exit_code, signal = pcall(function()
      return runtime:exited()
    end)
    if not exited_ok then return failure("provider_runtime_error", tostring(exited)) end
    return {
      status = exited and "exited" or "running",
      output = type(output) == "string" and output or "",
      exit_code = exited and exit_code or nil,
      signal = exited and signal or nil,
    }
  end

  provider.shutdown = provider.shutdown or function()
    return true
  end

  return provider
end

return Runtime
