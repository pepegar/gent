# gent

An extensible coding agent built as a lisp machine. Think Emacs, but for AI-assisted coding.

## Architecture

Rust provides low-level "syscalls" (terminal I/O, HTTP, process execution, JSON, async tasks). Janet owns everything else: the agent loop, tools, UI, hooks, conversation management, and configuration.

### Startup flow

1. `src/main.rs` boots a Janet VM via `janetrs`, registers native modules, sets `:syspath` to `janet/`
2. Runs `janet/boot.janet` — the entry point (like Emacs's `loadup.el`)
3. `boot.janet` imports core modules, built-in tools, slash commands, discovers skills/AGENTS.md, loads user/project config, then calls `(agent/run)` which starts the TUI reactor loop

### Layout

- `src/` — Rust native functions only (`main.rs` boots the VM, `native/` has the five modules)
- `janet/` — The entire agent in Janet: `boot.janet` is the entry point, `core/` has the runtime, `tools/` has built-in tools, `widgets/` has TUI widgets, `tui/` has rendering primitives, `commands/` has slash commands, `test/` has the test suite

### Key concepts

- **Tools**: Janet tables with `:name`, `:description`, `:schema`, `:function`. Registered via `(tools/register name def)`. Can be sync or async (`tools/async-tool`).
- **Hooks**: Emacs-style event hooks (`:before-tool-call`, `:after-tool-call`, `:before-send`, `:after-response`, `:on-error`, `:after-message`, etc.).
- **Sessions**: Append-only logs of Janet s-expressions at `~/.gent/sessions/<url-encoded-cwd>/<session-id>/history`. Crash-safe, forkable.
- **Skills**: Directories with `SKILL.md` (YAML frontmatter + body). Discovered from `.gent/skills/` and `.agents/skills/` walking up from cwd.
- **Widgets**: The TUI is a widget system. `agent.janet` is the reactor loop that polls events, dispatches to widgets, and does double-buffered diff rendering.
- **Config**: `~/.gent/init.janet` (user) and `.gent/init.janet` (project), loaded in `boot.janet`.

## Building

Requires Rust and Cargo:

```sh
# Debug build
cargo build

# Release build
cargo build --release
```

The binary is at `target/release/gent` (or `target/debug/gent`). It expects to find the `janet/` directory either relative to cwd or relative to the executable.

## Running

```sh
# From the project root (debug)
cargo run

# Or directly
./target/release/gent
```

## Testing

### Janet tests

Run the full Janet test suite from the project root:

```sh
janet janet/test/run.janet
```

This runs all test files listed in `janet/test/run.janet`. It sets up module paths, installs native function mocks (http, json, term, process) via `test/fake-http`, and executes each test module, reporting pass/fail/error counts. The exit code is non-zero if any test fails or errors.

Individual test files live in `janet/test/` (e.g. `test-hooks.janet`, `test-commands.janet`, `test-registers.janet`, etc.).

The test framework is `janet/test/helper.janet` — a minimal assertion library:

```janet
(import test/helper :as t)
(t/test "name" (fn [] (t/assert= 1 1)))
(t/test "truthy check" (fn [] (t/assert-truthy true)))
(t/test "falsy check" (fn [] (t/assert-falsy nil)))
```

Tests can run under plain `janet` (no Rust runtime needed) because `test/fake-http.janet` provides mocks for all native functions.

### Snapshot testing

Widget rendering is verified with buffer snapshot tests. The pattern:

1. Create a widget with a fixed rect via `setup`
2. Feed it state (call `output-user`, `output-agent`, `output-tool`, etc.)
3. Render into a `tui/buffer`
4. Extract plain text with `buffer-to-plain-rows` or inspect cell styles with `buffer-get`
5. Assert on text content or style properties

See `janet/test/test-snapshot.janet` — it is the canonical example for snapshot testing and covers layout, spacing, word wrapping, row backgrounds, color themes, and combined inspect+render assertions.

### Mandatory: verify build and tests after every change

After implementing any feature, bug fix, or modification, always verify that the project compiles and all tests pass:

```sh
cargo build && janet janet/test/run.janet
```

Fix all compilation errors and test failures before considering the work done. Do not skip this step.

### Rust tests

```sh
cargo test
```

There are currently no Rust-side unit tests — all logic lives in Janet. `cargo test` still compiles and runs the test harness (useful to verify the Rust code compiles cleanly).

### Check everything builds and tests pass

```sh
cargo build && janet janet/test/run.janet
```

## Profiling

Gent has a built-in span-based profiling system (`janet/core/profile.janet`) that records Chrome Trace Event JSON for visualization in [speedscope.app](https://speedscope.app).

### Enabling profiling

```sh
# Via environment variable (auto-enables on boot)
GENT_PROFILE=1 cargo run

# Or toggle during a session with slash commands
/profile start
/profile stop
```

### Collecting data

During a session:
- `/profile stats` — print a formatted table of per-operation timings (count, total, avg, min, max)
- `/profile dump` — export Chrome Trace Event JSON to `.gent/profile-<timestamp>.json`
- `/profile reset` — clear all profiling data (useful to isolate a specific interaction)

### Interactive profiling with tui-wright

For automated profiling of scroll, keyboard, and mouse interactions, use [tui-wright](https://github.com/pepegar/tui-wright) to spawn gent in a virtual terminal and send programmatic input:

```sh
# Spawn a bash shell (tui-wright daemon runs from $HOME, so use absolute paths or cd first)
tui-wright spawn bash --cols 100 --rows 30
# → session: abc123

# CD to the project and launch gent with profiling
tui-wright type abc123 "cd /path/to/gent && GENT_PROFILE=1 ./target/debug/gent"
tui-wright key abc123 enter
sleep 3

# Send input
tui-wright type abc123 "Hello, what is 2+2?"
tui-wright key abc123 enter
sleep 10

# Send mouse scroll events
tui-wright mouse abc123 scrollup 50 15
tui-wright mouse abc123 scrolldown 50 15

# Read the screen
tui-wright screen abc123

# Get profile stats
tui-wright type abc123 "/profile stats"
tui-wright key abc123 enter
sleep 0.5
# Scroll to bottom to see the output
for i in $(seq 1 500); do tui-wright mouse abc123 scrolldown 50 15; done
sleep 1
tui-wright screen abc123

# Export trace and clean up
tui-wright type abc123 "/profile dump"
tui-wright key abc123 enter
sleep 0.5
tui-wright key abc123 ctrl+c
sleep 1
tui-wright kill abc123
```

**Important notes for tui-wright + gent:**
- The tui-wright daemon starts from `$HOME`, not the current directory. Always `cd` to the gent project root first, or use absolute paths.
- Add `sleep` between actions — TUI apps need time to process input and redraw (0.2-0.5s after key/mouse events, 1-3s after launching gent or sending an LLM prompt).
- Scroll events are coalesced by gent's reactor — rapid bursts will be batched into fewer dispatches. Use `/profile stats` with the `event:scroll` row's `coalesced` metadata in the trace to verify batching behavior.
- Profile traces can be opened in https://speedscope.app for flame-graph visualization of nested spans (`reactor:loop` → `render:frame` → `render:chat`, etc.).

### Key profiling spans

| Span | Category | What it measures |
|------|----------|-----------------|
| `reactor:loop` | reactor | One full iteration of the event loop |
| `event:poll` | io | Blocking wait for terminal event (includes idle time) |
| `event:scroll` | event | Scroll event coalescing and dispatch |
| `event:key` | event | Key event batching and dispatch |
| `render:frame` | render | Full frame render (includes widget renders + diff + ANSI emission) |
| `render:chat` | render | Chat widget render into buffer |
| `render:editor` | render | Editor widget render |
| `render:separator` | render | Separator widget render |
| `stream:api-call` | stream | LLM API streaming call (wall clock) |
| `stream:drain` | stream | Reading chunks from the HTTP stream |
| `widget:update-all` | update | Per-frame widget polling (chat drains stream, polls tools) |
| `tool:*` | tool | Individual tool execution (auto-instrumented via hooks) |

## Dependencies

- **Rust** + **Cargo** for building
- **[Janet](https://janet-lang.org/)** — embedded via [janetrs](https://crates.io/crates/janetrs) (no separate Janet install needed for building)
- **`janet` CLI** — needed to run the test suite (install separately: `brew install janet` or from source)
- **[ureq](https://crates.io/crates/ureq)** — HTTP client
- **[crossterm](https://crates.io/crates/crossterm)** — Terminal handling
- **[serde_json](https://crates.io/crates/serde_json)** — JSON serialization
- **[libc](https://crates.io/crates/libc)** — Unix-only, for process suspension (SIGTSTP)
