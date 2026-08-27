local make = require "plugins.workbench.provider.builtin.agent_cli"

return make {
  id = "builtin.opencode",
  executable = "opencode",
  model_flag = "--model",
  agent_flag = "--agent",
  auto_flag = "--auto",
  prompt_flag = "--prompt",
}
