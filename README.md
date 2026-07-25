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
service/                 # UI-independent shared Lua service (planned)
agent/                   # Optional persistent agent (planned)
native/                  # Optional native runtime bindings (planned)
tests/                   # Service and protocol tests (planned)
fixtures/                # Migration and protocol fixtures (planned)
docs/                    # Architecture and implementation plans
```

When this repository is checked out as `data/plugins/workbench` inside
Pragtical, the Lua files at its root are installed directly as the
`plugins.workbench` plugin.

See [docs/workbench-plan.md](docs/workbench-plan.md) for the architecture,
milestones, and acceptance criteria.

