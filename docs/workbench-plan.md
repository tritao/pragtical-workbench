# Pragtical Workbench plan

## Decision

Build Workbench as a Pragtical-native, Lua-first subsystem in this repository.
Sakura Core is not refactored or used as the new domain implementation. It is
treated as:

- a reference for useful features and workflows;
- a source of migration fixtures;
- a source of behavior to reproduce where it benefits Pragtical users.

The authoritative workspace implementation is shared Lua code. It runs
in-process inside Pragtical and, later, inside an optional Workbench agent.
Native code is reserved for platform integration and high-throughput paths.

```text
Pragtical
├── Shared Workbench Lua service
│   ├── workspace model and commands
│   ├── validation, revisions, and events
│   ├── resources and providers
│   ├── persistence orchestration
│   └── Sakura migration
├── Pragtical Workbench plugin
│   ├── sidebar, commands, and views
│   ├── client layout persistence
│   └── provider UI
├── Native Workbench runtime
│   ├── PTY / ConPTY and process lifecycle
│   ├── terminal emulation
│   ├── IPC, queues, and wakeups
│   └── SQLite binding
└── Optional Workbench agent
    ├── embedded Lua host
    ├── persistent runtimes
    └── IPC server
```

## Goals and non-goals

### Goals

- Keep the workspace, task, resource, provider, and command model in Lua.
- Use one service implementation in both in-process and agent modes.
- Make the UI independent of whether its backend is local or remote.
- Support persistent terminal runtimes without making the daemon mandatory.
- Use Sakura only as an input to migration and feature discovery.
- Keep the initial implementation testable without the full Pragtical UI.

### Non-goals

- Replacing or substantially refactoring Sakura Core.
- Reproducing Sakura desktop geometry or widget state.
- Making the initial system fully event-sourced.
- Building a public multi-language SDK before the service model is stable.

## Repository layout

```text
service/
  init.lua
  service.lua
  command.lua
  validation.lua
  snapshot.lua
  event.lua
  workspace.lua
  collection.lua
  task.lua
  resource.lua
  runtime.lua
  storage.lua
  providers.lua
  schema/
  migration/

data/plugins/workbench/
  init.lua
  sidebar.lua
  commands.lua
  client.lua
  terminal_view.lua
  resource_view.lua
  state.lua
  providers/

native/
  lua_api.c
  event_queue.c
  transport.c
  sqlite.c
  terminal.c
  terminal_emulator.c
  pty_posix.c
  conpty_windows.c

agent/
  main.c
  lua_host.c
  server.c
```

The shared service must remain UI-independent so it can be loaded by both
Pragtical and the agent. The current repository root is the installed plugin
directory; the `service`, `native`, and `agent` directories are introduced as
their respective phases begin.

## Service boundary

Define the client interface before expanding the UI:

```lua
local client = workbench.open {
  backend = "in_process",
  workspace_id = "default",
}

local request_id = client:execute {
  type = "task.create",
  operation_id = uuid(),
  workspace_id = "default",
  expected_revision = 17,
  task = {
    title = "Investigate rendering issue",
    collection_id = collection_id,
  },
}
```

Both backends expose the same asynchronous API:

```lua
client:execute(command)
client:get_snapshot()
client:subscribe(callback)
client:get_runtime_output(runtime_id, offset)
client:write_runtime(runtime_id, data)
client:resize_runtime(runtime_id, columns, rows)
client:close()
```

The in-process backend dispatches directly to the shared Lua service. The
agent backend serializes the same command, result, and event table shapes.
The UI must use the asynchronous contract even when the backend is local.

For migrations, the client also exposes `execute_batch(commands)`. Importers
use this to apply a validated command plan in one service/SQLite transaction;
the agent carries the same batch as a MessagePack request.

## Lua-first domain model

Views and providers must not mutate model tables directly. Every mutation goes
through a command pipeline:

```text
Command → validator → handler → storage transaction
         → state update → typed events → result → commit
```

Commands contain `version`, `operation_id`, `workspace_id`,
`expected_revision`, and a command-specific payload. The first command set is:

```text
workspace.create       workspace.rename
collection.create      collection.rename
collection.move        collection.archive       collection.delete
task.create            task.update               task.move
task.archive           task.delete
resource.create        resource.update           resource.attach
resource.detach        resource.archive          resource.delete
runtime.start          runtime.stop              runtime.restart
runtime.delete_history
```

Use stable IDs and explicit ordering rather than cross-linked mutable object
references or Lua table iteration order. A workspace snapshot contains maps of
collections, tasks, and resources, plus the current revision.

The service owns validation, optimistic revision checks, idempotent operation
IDs, transactional state changes, typed events, snapshots, bounded event
replay, provider registration, and persistence orchestration.

## Native boundary

Native code should provide only the parts that Lua cannot implement portably or
should not process at high volume:

| Area | Owner |
| --- | --- |
| Workspace model, commands, validation, revisions, and events | Lua |
| SQLite schema, migrations, queries, and object mapping | Lua; native binding only |
| Provider registry and provider behavior | Lua; optional native hooks |
| Sidebar, commands, views, and layout state | Lua / Pragtical |
| POSIX PTY, ConPTY, process groups, signals, resize, and exit detection | Native |
| ANSI/VT parsing, cell widths, scrollback, cursor, damage, and reflow | Native |
| IPC framing, bounded queues, backpressure, wakeups, and lifecycle | Native transport; Lua protocol semantics |
| Sakura importer | Lua |
| Agent executable | Small native host embedding Lua |

Worker threads must never call Lua directly. Native workers publish through a
bounded queue and wake the Pragtical main thread with an SDL custom event:

```text
PTY or IPC worker → native bounded queue → SDL custom event
                   → Pragtical main thread → Lua callback
```

Prefer existing Pragtical and terminal-plugin primitives first. Any new core
API must be generic and independently useful to other plugins; Workbench
specific behavior stays in this repository.

## Persistence

Use SQLite for durable current state and a bounded event journal for connected
client replay. Do not initially require rebuilding the workspace by replaying
the complete event history.

Initial tables:

```text
workspaces             collections
tasks                  resources
runtimes               provider_metadata
operations             events
schema_migrations
```

Lua owns the schema and migration sequence:

```text
service/migration/
  001_initial.lua
  002_add_resources.lua
  003_add_runtime_history.lua
```

The native SQLite binding remains deliberately small and supports parameterized
execution and transactions. Persistence must update state, revision,
operation record, and events atomically, retain enough history for normal
reconnects, and fall back to a fresh snapshot when an event offset is gone.

## IPC and protocol

Use length-prefixed MessagePack control messages for the initial agent
protocol. Lua tables map naturally to MessagePack and this avoids parallel
generated C and Lua representations.

MessagePack is not schema-less. Define explicit Lua schemas for every command,
result, and event, including required fields, optional fields, size limits,
unknown-field behavior, and capability negotiation. Maintain a protocol-major
version and golden fixtures.

Terminal output carries a runtime ID, byte offset, and raw byte payload. Use
ordinary MessagePack first; introduce specialized binary terminal frames only
if profiling shows that dynamic control-message encoding is a bottleneck.
JSON-RPC may be added as an optional debugging endpoint, not as the primary
protocol.

## Agent mode

The agent is a small C executable that embeds the same Lua runtime and loads
the shared service. It initializes native facilities, configures Lua package
paths, opens SQLite, acquires the single-writer lock, listens on the platform
IPC endpoint, dispatches decoded commands to Lua, publishes results and events,
and owns terminal runtimes and history.

Shared Lua code must avoid LuaJIT FFI and implementation-specific extensions.
Target the common Lua subset supported by Pragtical and the agent.

In-process mode keeps the service, SQLite connection, and runtimes inside
Pragtical. Agent mode moves those responsibilities to the daemon while the
Pragtical client and views remain unchanged.

## Providers

Providers are Lua modules by default and register resource kinds, creation
behavior, and commands. Separate service providers from Pragtical UI providers:

```text
provider/service.lua
provider/pragtical.lua
```

The agent loads only explicitly trusted service providers and never arbitrary
Pragtical UI plugins. Initial provider order:

1. `builtin.shell`;
2. `git.repository`;
3. one external provider such as GitHub or Codex.

## Sakura migration

Migration is an independent feature, not a runtime compatibility layer:

```text
Sakura session → legacy parser → intermediate representation
               → validation and repair → Workbench commands/snapshot
               → SQLite transaction → migration report
```

Mappings:

```text
Sakura groups        → collections
Sakura tasks         → tasks
Sakura terminals     → terminal resources
Sakura shell/cwd     → resource configuration
Sakura archive data  → archived fields
Sakura ordering      → explicit order
```

Do not import GTK geometry, VTE-specific state, desktop widget state, sidebar
pixel dimensions, or unsupported integrations. The importer must support
dry-run, leave the source unchanged, create a backup before database changes,
report skipped fields, reject ambiguous references, produce deterministic
output where possible, and validate the result through the new service.

The first implementation is `data/plugins/workbench/sakura_import.lua`. It
parses Sakura's GLib `GKeyFile` session format independently, converts groups,
tasks, and terminal tabs to Workbench records, reports pages/layouts and
unsupported provider metadata as skipped, and exposes:

```lua
Importer.preview(session_path)
Importer.import_file(client, session_path)
```

The `workbench:import-sakura` command previews the import counts, warnings, and
skipped fields, then requires the user to type `import` before writing. Import
is refused when the source is malformed, references are ambiguous, a target ID
already exists, or the default backup path already exists. A dry run does not
create the backup or modify the target workspace. A sanitized real-world v8
session is checked in at `tests/fixtures/sakura-session-v8.conf`.

## Implementation phases

### Current status

The local persistence milestone is implemented. Workbench now has Lua-owned
SQLite migrations, normalized current-state storage, runtime and provider
metadata, idempotent operation records, bounded event replay with snapshot
fallback boundaries, and a bundled SQLite fallback selected by Meson when a
system SQLite dependency is unavailable.

The agent vertical slice is now implemented on POSIX: a small embedded-Lua
`workbench-agent` executable loads the same service, uses the shared framed
MessagePack protocol over a Unix socket, and supports handshake/capabilities,
commands, snapshots, subscriptions, replay recovery, and SQLite-backed
reconnect. The agent now also owns POSIX PTYs, persists raw output history,
streams bounded output events, accepts input and resize commands, and serves
byte-offset replay after client reconnect. ConPTY and Windows named-pipe
transport support are now implemented in the native boundary. The Windows CI
job runs the built binaries directly, covering SQLite persistence, named-pipe
handshake and reconnect, and the ConPTY terminal lifecycle.

### Phase 1 — Pure-Lua service

Implement and test the workspace, collections, tasks, resources, command
dispatcher, validation, revisions, operation IDs, snapshots, typed events, and
an in-memory store. Tests must run without the full Pragtical UI.

### Phase 2 — UI against a fake client

Build the sidebar, commands, tree projection, resource-opening behavior, error
handling, and local layout state against a fake backend.

### Phase 3 — In-process backend

Connect the Pragtical client to the shared Lua service and verify that every
domain mutation still flows through commands.

### Phase 4 — Native terminal vertical slice (implemented on POSIX)

Implement POSIX PTY support, a mock PTY, terminal emulation, event queues,
`TerminalView`, start/stop/detach/reattach, resize, and large-output handling.
The POSIX PTY and in-process path are implemented, and the agent now exposes
the shared runtime on Windows as well; direct Windows CI validation now covers
the agent path and ConPTY lifecycle.

### Phase 5 — SQLite persistence

Add the Lua-owned schema and migrations, native SQLite binding, transactional
commands, operation history, bounded event journal, and runtime metadata.

### Phase 6 — Agent host (POSIX vertical slice implemented)

Add the embedded-Lua daemon, IPC transport, MessagePack schemas, handshake,
capabilities, subscriptions, reconnect, snapshot recovery, and terminal offset
replay. The embedded agent, Unix transport, POSIX runtime ownership, history,
input, resize, replay, ConPTY, and Windows named-pipe transport are implemented
in source. The Windows CI job now validates the direct binary and agent paths;
MSVC-specific end-to-end validation remains.

### Phase 7 — Sakura importer

The independent importer, dry-run report, source backup, command batch, SQLite
transaction, validation, confirmation UX, and Pragtical command are
implemented. Remaining work is broader fixture coverage and migration UX
polish.

### Phase 8 — Providers

Add providers after resources, terminal lifecycle, and parity between
in-process and agent backends are working.

## Milestones and acceptance criteria

### Milestone 1: local Workbench

Deliver the shared Lua service, in-memory store, sidebar, collections, tasks,
terminal resources, native POSIX PTY, terminal emulator, `TerminalView`,
in-process backend, and layout persistence.

A user can create a workspace, organize tasks, create multiple terminal
resources, split and arrange views, close and reopen views, restore the layout,
and perform every domain mutation through commands.

### Milestone 2: persistent Workbench

Deliver SQLite persistence, the agent daemon, MessagePack, persistent terminal
runtimes and history, reconnect and replay, snapshot recovery, ConPTY, and
Sakura migration.

A user can leave terminal processes running while Pragtical closes, reopen the
editor, reconnect, restore local layout, replay missed output, and import an
old Sakura session once.

## Verification and guardrails

- Unit-test validation, revision conflicts, idempotency, ordering, and event
  shapes against the in-memory service.
- Use golden fixtures for commands, results, events, snapshots, and protocol
  negotiation.
- Apply migrations to empty and representative existing databases.
- Exercise PTY and terminal behavior with mock streams, large output,
  malformed output, and resize-heavy output.
- Run service tests in both the Pragtical and agent hosts.
- Test importer dry-runs, malformed references, skipped fields, backups, and
  final service validation.
- Keep native queues bounded and define backpressure before streaming output.
- Enforce IPC message and terminal chunk size limits.
- Treat operation IDs and revision checks as mandatory for mutation.
- Do not let Sakura compatibility leak into the new domain model.

## Final architecture

```text
Standalone Workbench plugin repository
Shared Lua domain and service
Native platform/runtime primitives when required
Framed MessagePack IPC
Optional JSON-RPC diagnostics
One-off Sakura importer
```
