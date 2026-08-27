# Pragtical Workbench

Workbench is an optional Pragtical plugin for workspace organization, tasks,
resources, terminal sessions, and provider-backed workflows.

The project is intentionally developed outside Pragtical core. Its domain
model and service are Lua-first; native code is reserved for PTY/ConPTY,
terminal emulation, IPC, queues, and other platform or throughput boundaries.

The plugin is currently under active development. The native Workbench backend
is optional, and the plugin should remain loadable when that backend is not
available.

## Repository layout

```text
data/plugins/workbench/  # Installed Pragtical plugin files in this repository
service/                 # UI-independent shared Lua service
agent.lua                # Optional persistent agent server
tests/                   # Service, protocol, and agent integration tests
docs/                    # Architecture and implementation plans

src/api/workbench_transport.c
src/workbench-agent/main.c
```

The in-process backend is selected with `backend = "in_process"`. The
persistent POSIX agent can be started with:

```text
workbench-agent --data-root /path/to/pragtical/data \
  --data-dir /path/to/workbench-state \
  --endpoint /path/to/workbench-state/workbench.sock \
  --workspace default
```

The client selects it with `backend = "agent"` and the same `endpoint`.
When no endpoint is supplied on POSIX, the client uses
`$XDG_RUNTIME_DIR/pragtical/workbench/<workspace>.sock`; explicit endpoints
must be in a user-owned, non-group-writable directory. The agent is a single
Lua authority serving multiple clients. Its current
vertical slice supports SQLite-backed workspace commands,
snapshots, event subscriptions, replay recovery, reconnect, POSIX PTY ownership,
bounded per-client output queues with nonblocking drains, byte-offset history,
input, resize, and terminal replay.
ConPTY and Windows named-pipe transport support are now implemented in the
native boundary; the Windows CI job now exercises the built agent, named-pipe
transport, ConPTY terminal lifecycle, persistence, and reconnect paths.

Commands can be submitted without blocking the caller:

```lua
local request = client:execute(command, function(result, error)
  if error then return end
  -- apply result
end)

client:poll()
request:cancel()
```

Requests have bounded deadlines, expose `is_done()` and `result()`, and are
completed from `poll()`. The callback form is shared by the agent and
in-process backends; the no-callback form remains a bounded synchronous
convenience wrapper.

## Providers

Providers are trusted service modules registered with Workbench. Each provider
declares its resource kinds, capabilities, supported actions, and event types,
and implements resource creation/update validation, runtime specification,
runtime metadata, and provider metadata validation. The built-in
`builtin.shell`, `builtin.codex`, and `builtin.opencode` providers own terminal
resources and native PTY launch options; the generic Workbench records do not
contain provider-specific fields. Codex and OpenCode settings such as the
executable, model, prompt, working directory, and approval mode are
provider-owned configuration or runtime options.

Clients can inspect the registered provider contract through
`client:providers()` or the `providers` field in a snapshot. Provider runtime
actions are checked by the agent before execution, so a future provider can
expose resources without implicitly receiving shell/runtime behavior.

The service-side lifecycle boundary is exposed by the provider registry:
`available`, `create`, `attach`, `recover`, `start`, `stop`, `restart`,
`send_input`, `action`, `refresh_status`, `capabilities`, and `shutdown`.
The built-in shell uses this boundary for PTY creation, polling, input,
resize, and shutdown. Its `attach` and `recover` operations explicitly report
that native shell runtimes cannot be reattached after the agent disappears;
the durable runtime record is instead reconciled as `interrupted`.

Runtime execution policy is provider-neutral and is stored separately from
provider configuration. Its canonical shape is:

```text
{
  approval = "prompt" | "auto",
  sandbox = "read-only" | "workspace" | "full",
  permissions = {
    filesystem = "deny" | "prompt" | "allow",
    network = "deny" | "prompt" | "allow",
    process = "deny" | "prompt" | "allow"
  }
}
```

Providers translate this policy into their own control surface. The built-in
Codex adapter maps the generic sandbox and approval values to its CLI flags;
legacy `sandbox` and `approval_policy` runtime options remain accepted while
clients migrate to `execution_policy`.

## Sidebar behavior

Workbench shares Pragtical's single left sidebar slot with Files. By default,
the first launch opens Workbench and later launches restore the last selected
mode and visibility. Use `workbench:open` to switch to Workbench,
`workbench:show-files` to switch back to Files, and `workbench:toggle` to hide
or restore the shared sidebar.

The startup policy can be configured as `restore`, `always`, or `never` with
`config.plugins.workbench.startup`.

Use `workbench:create-codex` or `workbench:create-opencode` to create a
provider-backed interactive agent terminal. The corresponding resource keeps
the provider ID and opaque provider configuration; runtime lifecycle and
history remain Workbench-owned.

## Testing

The regular Pragtical test suite does not require an agent process. Run the
complete Workbench suite, including agent persistence and terminal tests, with:

```text
SDL_VIDEO_DRIVER=dummy ./scripts/test-workbench.sh build
```

The runner creates temporary agent state and endpoints, restarts the agent for
the persistence test, and cleans everything up afterward. Individual agent
test files can still be run directly by setting `WORKBENCH_AGENT_ENDPOINT` to
an already-running compatible agent.

When this repository is checked out as `data/plugins/workbench` inside
Pragtical, the Lua files at its root are installed directly as the
`plugins.workbench` plugin.

See [docs/workbench-plan.md](docs/workbench-plan.md) for the architecture,
milestones, and acceptance criteria.
