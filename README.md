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
native boundary; Windows CI remains the verification gate.

When this repository is checked out as `data/plugins/workbench` inside
Pragtical, the Lua files at its root are installed directly as the
`plugins.workbench` plugin.

See [docs/workbench-plan.md](docs/workbench-plan.md) for the architecture,
milestones, and acceptance criteria.
