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

### Janet code style (parinfer)

Gent uses [parinfer](https://shaunlebron.github.io/parinfer/) to manage parentheses in Janet source files. The tool `parinfer-rust` is available in the dev shell (`nix develop`) and as a gent tool (`parinfer`).

**How it works**: In Lisp, indentation and parentheses encode the same structure. Parinfer formalizes this — given correct indentation, it infers the right closing parens, and vice versa. We use **paren mode** for formatting: it adjusts indentation to match existing parentheses.

**Rules for writing Janet code**:

- **Two-space indent** is the convention. Nested forms indent two spaces from their parent.
- **Indentation is structural** — it determines where expressions begin and end. Get indentation right and parens follow.
- **Don't hand-tune trailing parens** at line ends. Parinfer rewrites them based on indentation. Stacking closing parens on their own line is never needed.
- **One expression per line** when a form spans multiple lines. Align sibling arguments at the same column.
- Run `parinfer-rust -m paren -l janet < file.janet` to check formatting, or use the `parinfer` tool inside a gent session.
- CI runs `nix flake check` which verifies all `.janet` files pass parinfer paren mode.

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

### Digital Twin (DTU) tests

The `twins/` directory contains Python (FastAPI) servers that behaviorally clone the Anthropic and OpenAI APIs. They run in Docker containers and enable full HTTP path testing — headers, auth, request bodies, SSE streaming, error handling.

**Python unit tests** (no Docker needed):

```sh
cd twins && python3 -m pytest tests/ -v
```

**E2E tests** (requires Docker + tui-wright):

```sh
bash test/twin-all.sh
```

This starts the twin containers, runs all Python unit tests, Janet tests, and 5 E2E test suites that verify the full HTTP path through real gent sessions.

Individual E2E scripts:

- `test/twin-e2e.sh` — Full round-trip (enqueue → request → SSE → TUI)
- `test/twin-auth.sh` — Auth header verification + 401 rejection
- `test/twin-provider-switch.sh` — Anthropic vs OpenAI wire format
- `test/twin-error-handling.sh` — HTTP error codes + recovery
- `test/twin-error-scenarios.sh` — Comprehensive error scenarios (403, 500, 529, tool calls, thinking, multi-turn)

The twins expose a control plane for scripting responses:

```sh
# Enqueue a response
curl -X POST http://localhost:18080/__control/enqueue \
  -H 'Content-Type: application/json' \
  -d '{"type":"text","content":"Hello!"}'

# Inspect captured requests
curl http://localhost:18080/__control/requests
```

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

## Commits

This project uses [Conventional Commits](https://www.conventionalcommits.org/). All commit messages **must** follow this format:

```
<type>(<optional scope>): <description>
```

### Types

- `feat` — new feature (bumps minor version)
- `fix` — bug fix (bumps patch version)
- `refactor` — code change that neither fixes a bug nor adds a feature
- `chore` — build, CI, tooling, or dependency changes
- `docs` — documentation only
- `test` — adding or fixing tests
- `perf` — performance improvement
- `style` — formatting, whitespace (not CSS)
- `ci` — CI/CD changes
- `build` — build system changes

### Examples

```
feat: add file picker widget
feat(tui): word wrap for wide characters
fix: scroll offset clamp on resize
refactor(hooks): simplify dispatch loop
chore: bump janetrs to 0.9
docs: add profiling section to AGENTS.md
test: snapshot tests for dialog widget
```

### Breaking changes

Append `!` after the type for breaking changes:

```
feat!: remove legacy session format
refactor(api)!: rename provider config keys
```

Release Drafter uses these prefixes to auto-categorize release notes.

## Dependencies

- **Rust** + **Cargo** for building
- **[Janet](https://janet-lang.org/)** — embedded via [janetrs](https://crates.io/crates/janetrs) (no separate Janet install needed for building)
- **`janet` CLI** — needed to run the test suite (install separately: `brew install janet` or from source)
- **[ureq](https://crates.io/crates/ureq)** — HTTP client
- **[crossterm](https://crates.io/crates/crossterm)** — Terminal handling
- **[serde_json](https://crates.io/crates/serde_json)** — JSON serialization
- **[libc](https://crates.io/crates/libc)** — Unix-only, for process suspension (SIGTSTP)
