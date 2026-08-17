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
The current agent vertical slice supports SQLite-backed workspace commands,
snapshots, event subscriptions, replay recovery, reconnect, POSIX PTY ownership,
bounded output queues, byte-offset history, input, resize, and terminal replay.
ConPTY and Windows named-pipe transport support are now implemented in the
native boundary; the Windows CI job now exercises the built agent, named-pipe
transport, ConPTY terminal lifecycle, persistence, and reconnect paths.

## Sidebar behavior

Workbench shares Pragtical's single left sidebar slot with Files. By default,
the first launch opens Workbench and later launches restore the last selected
mode and visibility. Use `workbench:open` to switch to Workbench,
`workbench:show-files` to switch back to Files, and `workbench:toggle` to hide
or restore the shared sidebar.

The startup policy can be configured as `restore`, `always`, or `never` with
`config.plugins.workbench.startup`.

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
