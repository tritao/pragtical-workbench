local make = require "plugins.workbench.provider.builtin.agent_cli"

return make {
  id = "builtin.codex",
  executable = "codex",
  model_flag = "-m",
  sandbox_flag = "-s",
  approval_flag = "-a",
  profile_flag = "-p",
}
