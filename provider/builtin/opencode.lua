local make = require "plugins.workbench.provider.builtin.agent_cli"

return make {
  id = "builtin.opencode",
  executable = "opencode",
  model_flag = "--model",
  agent_flag = "--agent",
  auto_flag = "--auto",
  prompt_flag = "--prompt",
  map_policy = function(policy)
    if policy.sandbox ~= nil then
      return nil, "provider does not support execution_policy.sandbox"
    end
    return {
      auto = policy.approval == "auto",
      permissions = policy.permissions,
    }
  end,
}
