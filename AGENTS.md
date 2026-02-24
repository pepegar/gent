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

## Dependencies

- **Rust** + **Cargo** for building
- **[Janet](https://janet-lang.org/)** — embedded via [janetrs](https://crates.io/crates/janetrs) (no separate Janet install needed for building)
- **`janet` CLI** — needed to run the test suite (install separately: `brew install janet` or from source)
- **[ureq](https://crates.io/crates/ureq)** — HTTP client
- **[crossterm](https://crates.io/crates/crossterm)** — Terminal handling
- **[serde_json](https://crates.io/crates/serde_json)** — JSON serialization
- **[libc](https://crates.io/crates/libc)** — Unix-only, for process suspension (SIGTSTP)
