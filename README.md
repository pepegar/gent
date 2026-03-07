# gent

**The programmable coding agent.**

gent is an open source AI coding agent with a scripting engine at its core. It runs in your terminal, works with the model and endpoint you choose, and gives you something most agents do not: a real programming language for changing how the agent behaves while it is running.

Other agents give you config files. gent gives you a programmable runtime.

## Quick start

```sh
cargo build --release
./target/release/gent
```

You are in a terminal session with an AI coding agent. Ask it to read files, write code, and run tests. Then ask it to:

> Make a tool that runs my test suite and summarizes failures.

gent will not just run the tests. It can create a reusable tool for that workflow, live, in the same conversation.

## The idea

Most coding agents are fixed products. You can adjust settings, but you cannot really change how they think, act, or present themselves.

gent takes a different approach. The agent loop, tools, hooks, slash commands, UI, and conversation management are all part of a runtime you can inspect and modify. The LLM has access to that runtime too, which means it can build tools, wire up hooks, add commands, and query its own state as part of solving a task.

This is not a plugin API bolted onto the side. The runtime itself is programmable.

## Architecture

A thin Rust layer provides low-level primitives: terminal I/O, HTTP, process execution, and JSON. Everything above that is written in [Janet](https://janet-lang.org/), a lightweight embeddable language shipped inside the binary.

```
+--------------------------------------------------+
|              Programmable Runtime                 |
|                                                  |
|  Agent loop · Tools · Hooks · UI · Sessions      |
|  Commands · Skills · Registers · Buffers         |
|                                                  |
|  All written in Janet. All modifiable at runtime.|
+--------------------------------------------------+
|                Rust Primitives                    |
|  term/  ·  http/  ·  process/  ·  json/          |
+--------------------------------------------------+
```

## What "programmable" means in practice

### Define tools at runtime

Ask gent to make a ripgrep tool and it can write one live:

```janet
(import core/tools :as tools)

(tools/register "rg"
  {:description "Search with ripgrep"
   :schema {:type "object"
            :properties {:pattern {:type "string"}
                         :path {:type "string"}}
            :required ["pattern"]}
   :function (fn [input]
               (def result (process/exec "rg" ["--json" (get input :pattern) (or (get input :path) ".")]))
               (if (= 0 (get result :status))
                 (get result :stdout)
                 (string "No matches.")))})
```

No restart. The tool is available immediately in the same conversation.

### Intercept behavior with hooks

Log every tool call:

```janet
(import core/hooks :as hooks)

(hooks/add :before-tool-call
  (fn [name input]
    (spit "tool-log.txt"
          (string name " " (string/format "%q" input) "\n")
          :a)))
```

Block edits to protected paths:

```janet
(hooks/add :before-tool-call
  (fn [name input]
    (when (and (= name "edit_file")
               (string/has-prefix? "vendor/" (get input :path "")))
      (error "Refusing to edit vendor/ files"))))
```

### Query the agent's own state

```janet
(import core/conversation :as conv)
[(conv/length) (conv/estimate-tokens)]
# => [42 12500]

(import core/tools :as tools)
(tools/list-registered)
# => @["bash" "read_file" "list_files" "edit_file" "eval_janet" "use_skill" "rg"]
```

### Extend the command system

```janet
(import core/commands :as commands)
(import core/registers :as reg)

(commands/register "todo"
  {:description "Manage a todo list"
   :usage "/todo [item]"
   :function (fn [args]
               (var todos (or (reg/get :todos) @[]))
               (if (= "" args)
                 (if (empty? todos) "No todos."
                   (string/join (seq [i :range [0 (length todos)]]
                                  (string (+ i 1) ". " (get todos i))) "\n"))
                 (do (array/push todos args)
                     (reg/set :todos todos)
                     (string "Added: " args))))})
```

## Features

- **Programmable tools** — Create, replace, or extend tools at runtime. The LLM can build its own tools mid-conversation.
- **Event hooks** — Intercept tool calls, responses, and errors with hooks like `:before-tool-call`, `:after-response`, and `:on-error`.
- **Skills** — Domain-specific instruction modules following the [agentskills.io](https://agentskills.io) spec and loaded on demand.
- **AGENTS.md** — Project-specific context collected by walking up from the current working directory.
- **Crash-safe sessions** — Append-only s-expression logs you can resume, fork, and roll back.
- **Extensible commands** — Built-in slash commands plus your own runtime-defined commands.
- **Buffers and registers** — Composable text editing and persistent named storage within a session.
- **Non-blocking streaming** — SSE streaming with concurrent terminal input.
- **Open model routing** — Point gent at a local proxy or hosted API and choose the model yourself.

## Built-in tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands |
| `read_file` | Read file contents |
| `list_files` | List files and directories (respects `.gitignore`) |
| `edit_file` | Make targeted edits to text files |
| `eval_janet` | Evaluate code in the running agent |
| `use_skill` | Activate a skill for specialized instructions |

`eval_janet` is the key primitive. It gives both the user and the LLM access to the live runtime: tools, hooks, commands, UI, and conversation state.

## Configuration

Config files are scripts that run at startup:

1. **`~/.gent/init.janet`** — Personal setup
2. **`.gent/init.janet`** — Project-specific setup

```janet
# Choose your endpoint and model
(import core/api :as api)
(api/set-url "http://localhost:4000/v1/messages")
(api/set-model "anthropic/claude-sonnet-4-20250514")

# Shape the agent
(import core/agent :as agent)
(agent/set-system-prompt "You are a Haskell expert...")

# Define tools
(import core/tools :as tools)
(tools/register "grep"
  {:description "Search for a pattern in files"
   :schema {:type "object"
            :properties {:pattern {:type "string"}}
            :required ["pattern"]}
   :function (fn [input]
               (def result (process/exec "grep" ["-rn" (get input :pattern) "."]))
               (if (= 0 (get result :status))
                 (get result :stdout)
                 "No matches."))})

# Observe the pipeline
(import core/hooks :as hooks)
(hooks/add :before-tool-call (fn [name input] (print "calling tool:" name)))
```

Because config is just code, anything the agent can do, your config can do too.

## Skills

Skills are directories containing a `SKILL.md` file with YAML frontmatter. They are discovered from:

- `.gent/skills/` walking up from `cwd` to `/`
- `.agents/skills/` walking up from `cwd` to `/`
- `GENT_SKILLS_PATH` as a colon-separated list

Only the name and description are loaded at startup. Full instructions load on demand when the LLM activates the skill.

## Sessions

Conversations are persisted as append-only logs at:

```text
~/.gent/sessions/<url-encoded-cwd>/<session-id>/history
```

Each message is a structured s-expression, one per line. The format is crash-safe, human-readable, and easy to inspect.

- `/sessions` — List sessions
- `/resume <id>` — Resume a session
- `/fork` / `/unfork` — Branch and return
- `/rollback <n>` — Remove the last `n` messages

## Usage

```sh
gent                    # Start interactive session
gent --help             # Show help
gent --version          # Show version
gent -l setup.janet     # Load a custom script
gent -q                 # Skip config files
gent --headless         # Programmatic mode
gent --port 8080        # Custom RPC port
```

Once running, use slash commands like `/help`, `/skills`, `/tools`, `/session`, and `/quit`.

## Building

Requires Rust and Cargo:

```sh
cargo build --release
```

## Dependencies

- **[Janet](https://janet-lang.org/)** — Embedded via [janetrs](https://crates.io/crates/janetrs)
- **[ureq](https://crates.io/crates/ureq)** — HTTP client
- **[crossterm](https://crates.io/crates/crossterm)** — Terminal handling
- **[serde_json](https://crates.io/crates/serde_json)** — JSON serialization

## License

MIT
