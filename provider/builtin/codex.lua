local make = require "plugins.workbench.provider.builtin.agent_cli"

return make {
  id = "builtin.codex",
  executable = "codex",
  model_flag = "-m",
  sandbox_flag = "-s",
  approval_flag = "-a",
  sandbox_values = {
    ["read-only"] = "read-only",
    workspace = "workspace-write",
    full = "danger-full-access",
  },
  approval_values = {
    prompt = "on-request",
    auto = "never",
  },
  profile_flag = "-p",
}
