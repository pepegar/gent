# gent

> *Think Emacs, but for AI-assisted coding.*

An extensible coding agent built as a lisp machine.

gent is a terminal-based AI coding agent where the entire runtime — the agent loop, tools, UI, and configuration — is written in [Janet](https://janet-lang.org/), a small Lisp. Rust provides only the low-level "syscalls" (terminal I/O, HTTP, process execution, JSON), and from there Janet owns everything. Think Emacs, but for AI-assisted coding.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                  Janet Runtime                  │
│                                                 │
│  boot.janet ─→ core modules ─→ agent loop       │
│                                                 │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │   Tools   │ │   Hooks   │ │ Conversation  │  │
│  │  registry │ │  system   │ │  persistence  │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │  Skills   │ │ Registers │ │   Commands    │  │
│  │ discovery │ │  storage  │ │   (slash)     │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │  Buffers  │ │ AGENTS.md │ │      UI       │  │
│  │  (editor) │ │ discovery │ │   (TUI)       │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
├─────────────────────────────────────────────────┤
│           Rust Native Functions                 │
│  term/  ·  http/  ·  process/  ·  json/         │
└─────────────────────────────────────────────────┘
```

Rust boots a Janet VM, registers four native modules, and runs `boot.janet`. From that point, Janet handles everything: loading core modules, discovering skills and `AGENTS.md` files, loading user/project config, and entering the agent loop.

## Features

- **Runtime-extensible tools** — The LLM can create new tools on the fly by evaluating Janet code. Users can register tools from config files too.
- **Hooks system** — Emacs-style hooks (`:before-tool-call`, `:after-response`, `:on-error`, etc.) let you intercept and transform every part of the agent's behavior.
- **Skills** — Discoverable skill modules following the [agentskills.io](https://agentskills.io) spec. Skills provide domain-specific instructions that are loaded on demand.
- **AGENTS.md** — Walks up from `cwd` to `/` collecting `AGENTS.md` files for project-specific context, injected into the system prompt.
- **Session persistence** — Conversations are append-only logs of Janet s-expressions, crash-safe and inspectable. Fork, resume, and rollback sessions.
- **Slash commands** — Built-in commands (`/help`, `/session`, `/fork`, `/rollback`, `/clear`, `/tokens`, etc.) with an extensible command registry.
- **Buffers** — Emacs-inspired buffer abstraction for composable text editing with dirty tracking and hooks integration.
- **Registers** — Named key-value storage slots that persist across the session.
- **Streaming** — Non-blocking SSE streaming with concurrent terminal input handling.
- **Configurable** — `~/.gent/init.janet` (user config) and `.gent/init.janet` (project config), just like `~/.emacs` and `.dir-locals.el`.

## Built-in Tools

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands |
| `read_file` | Read file contents |
| `list_files` | List files and directories (respects `.gitignore`) |
| `edit_file` | Make targeted edits to text files |
| `eval_janet` | Evaluate Janet code in the running agent |
| `use_skill` | Activate a skill for specialized instructions |

## eval_janet — the Self-Modification Primitive

This is what makes gent a lisp machine. The LLM has full access to the running Janet VM and can reprogram itself mid-conversation. This isn't a toy — the entire agent (tools, hooks, commands, UI, conversation) is Janet data that `eval_janet` can read and write.

### Create tools on the fly

Ask gent to "make a tool that searches my codebase with ripgrep" and it will:

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

The tool is immediately available — gent will use it in the same conversation.

### Hook its own behavior

Ask gent to "log every tool call to a file" and it wires itself up:

```janet
(import core/hooks :as hooks)

(hooks/add :before-tool-call
  (fn [name input]
    (spit "tool-log.txt"
          (string name " " (string/format "%q" input) "\n")
          :a)))
```

Or "refuse to edit anything in vendor/":

```janet
(hooks/add :before-tool-call
  (fn [name input]
    (when (and (= name "edit_file")
               (string/has-prefix? "vendor/" (get input :path "")))
      (error "Refusing to edit vendor/ files"))))
```

### Introspect its own state

Ask "how big is our conversation?" or "what tools do you have?" and gent inspects itself:

```janet
(import core/conversation :as conv)
[(conv/length) (conv/estimate-tokens)]
# => [42 12500]

(import core/tools :as tools)
(tools/list-registered)
# => @["bash" "read_file" "list_files" "edit_file" "eval_janet" "use_skill" "rg"]
```

### Register slash commands

Ask gent to "add a /todo command" and it creates a persistent task list:

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

### Tune the UI

```janet
(import core/ui :as ui)
(ui/set-tool-result-max-lines 50)  # show more output
```

### The key insight

In most agents, the LLM is a passenger — it can call tools but can't change the vehicle. In gent, `eval_janet` means the LLM is the mechanic too. It can build new tools, rewire hooks, add commands, change the UI — all without restarting. This is the Emacs philosophy applied to AI agents.

## Configuration

gent loads config from two places, in order:

1. **`~/.gent/init.janet`** — User config (like `~/.emacs`)
2. **`.gent/init.janet`** — Project config (like `.dir-locals.el`)

```janet
# Point at a LiteLLM proxy
(import core/api :as api)
(api/set-url "http://localhost:4000/v1/messages")
(api/set-model "anthropic/claude-sonnet-4-20250514")

# Change the system prompt
(import core/agent :as agent)
(agent/set-system-prompt "You are a Haskell expert...")

# Define a custom tool
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

# Add hooks
(import core/hooks :as hooks)
(hooks/add :before-tool-call (fn [name input] (print "calling tool:" name)))
(hooks/add :after-tool-call (fn [name input result] (printf "tool %s done" name)))
```

## Skills

Skills are directories containing a `SKILL.md` file with YAML frontmatter. They're discovered from:

- `.gent/skills/` (walking up from cwd to `/`)
- `.agents/skills/` (walking up from cwd to `/`)
- `GENT_SKILLS_PATH` environment variable (colon-separated)

Skills use progressive disclosure: only the name and description are loaded at startup (~100 tokens). The full instructions are loaded only when the LLM activates the skill via the `use_skill` tool.

## Sessions

Conversations are persisted as append-only logs at:

```
~/.gent/sessions/<url-encoded-cwd>/<session-id>/history
```

Each message is a Janet s-expression, one per line — crash-safe, human-readable, and `cat`-friendly. Use slash commands to manage sessions:

- `/sessions` — List all sessions for the current project
- `/resume <id>` — Resume a previous session
- `/fork` — Fork the current session into a new one
- `/unfork` — Return to the parent session
- `/rollback <n>` — Remove the last n messages

## Usage

```sh
# Start interactive session
gent

# Show help
gent --help

# Show version
gent --version

# Load a custom setup script
gent -l setup.janet

# Start without loading config files
gent -q

# Run in headless mode (for programmatic use)
gent --headless

# Custom port for RPC server
gent --port 8080
```

Once running, use slash commands like `/help`, `/skills`, `/tools`, `/session`, `/quit`.

## Building

Requires Rust and Cargo:

```sh
cargo build --release
```

## Dependencies

- **[Janet](https://janet-lang.org/)** — Embedded via [janetrs](https://crates.io/crates/janetrs)
- **[ureq](https://crates.io/crates/ureq)** — HTTP client for API calls
- **[crossterm](https://crates.io/crates/crossterm)** — Terminal handling
- **[serde_json](https://crates.io/crates/serde_json)** — JSON serialization

## License

MIT

