---
name: configuration
description: Configure and customize gent through ~/.gent/init.janet. Use when the user asks to "configure gent", "change colors", "add hooks", "customize behavior", "modify themes", "create tools", "change UI settings", "set up gent", or wants to modify gent's appearance, behavior, or functionality.
---

# Configuring Gent

Gent is highly configurable through Janet code in configuration files. The main configuration files are:

- `~/.gent/init.janet` — User-level configuration (like `~/.emacs`)
- `.gent/init.janet` — Project-level configuration (like `.dir-locals.el`)

Configuration files are loaded during boot and have full access to gent's runtime.

## Quick Start

Create your configuration directory and file:

```bash
mkdir -p ~/.gent
touch ~/.gent/init.janet
```

## Common Customizations

### Theme Switching

```janet
(import widgets/chat :as chat)

# Auto-detect OS dark/light mode (default)
(chat/auto-theme)

# Or choose explicitly
(chat/set-theme :dark)   # Catppuccin Mocha
(chat/set-theme :light)  # Catppuccin Latte
```

### Custom Colors

Override specific colors while keeping a theme:

```janet
(import widgets/chat :as chat)

(chat/set-theme :dark)
(chat/set-colors
  @{:user-label  (tui/style :fg [:rgb 255 100 100] :bold true)
    :agent-label (tui/style :fg [:rgb 100 255 100] :bold true)})
```

**→ See [references/colors.md](references/colors.md) for complete color customization**

### UI Settings

```janet
(import widgets/chat :as chat)

# Show more tool output (default is 10 lines)
(chat/set-tool-result-max-lines 20)

# Custom system prompt
(chat/set-system-prompt
  "You are a helpful assistant specialized in [your domain].")
```

## Extending Behavior with Hooks

Hooks let you run code at key points. Example: log all tool calls.

```janet
(import core/hooks :as hooks)

(hooks/add :before-tool-call
  (fn [name input]
    (printf "Running tool: %s" name)))

(hooks/add :after-tool-call
  (fn [name input result]
    (printf "Tool %s completed" name)))
```

**→ See [references/hooks.md](references/hooks.md) for all hooks and advanced examples**

## Creating Custom Tools

```janet
(import core/tools :as tools)

(tools/register "timestamp"
  {:description "Get the current timestamp"
   :schema {:type "object" :properties {} :required []}
   :function (fn [input] (string (os/date)))})
```

**→ See [references/tools.md](references/tools.md) for async tools and complex schemas**

## Adding Slash Commands

```janet
(import core/commands :as commands)

(commands/register "hello"
  {:description "Say hello"
   :usage "/hello [name]"
   :function (fn [args]
               (string "Hello, " (if (empty? args) "World" args) "!"))})
```

**→ See [references/commands.md](references/commands.md) for full command examples**

## Configuration File Loading

Gent loads configuration files in this order:

1. `~/.gent/init.janet` (user config)
2. `.gent/init.janet` (project config)
3. Files specified via `-l` / `--load` flags

All config files are optional. Skip with `--no-init-file` or `-q`.

## Example Configuration

Here's a complete `~/.gent/init.janet` example:

```janet
# My gent configuration

# Theme
(import widgets/chat :as chat)
(chat/auto-theme)
(chat/set-colors @{:user-label (tui/style :fg [:rgb 100 150 255] :bold true)})

# UI settings
(chat/set-tool-result-max-lines 15)

# Simple tool logging
(import core/hooks :as hooks)
(hooks/add :before-tool-call
  (fn [name input]
    (spit (string (os/getenv "HOME") "/.gent/tool-log.txt")
          (string (os/date) " " name "\n")
          :a)))

# Custom tool
(import core/tools :as tools)
(tools/register "weather"
  {:description "Get weather for a city (mock)"
   :schema {:type "object"
            :properties {:city {:type "string" :description "City name"}}
            :required ["city"]}
   :function (fn [input]
               (string "Weather in " (get input :city) ": Sunny, 72°F"))})

(print "Loaded custom gent configuration!")
```

## Advanced Topics

- **[Color Customization](references/colors.md)** — Complete guide to all color keys and syntax
- **[Hooks](references/hooks.md)** — All hook types, guards, logging, custom rendering
- **[Custom Tools](references/tools.md)** — Async tools, complex schemas, external commands
- **[Slash Commands](references/commands.md)** — Command creation and examples
- **[Widget System](references/widgets.md)** — Build custom TUI widgets and layouts
- **[Advanced Config](references/advanced.md)** — Registers, API config, conditional config, modules

## Best Practices

1. **Start small** — begin with theme and basic settings
2. **Test incrementally** — use `eval_janet` to test code before adding to config
3. **Handle errors** — wrap risky operations in `try`/`catch`
4. **Use comments** — document your customizations
5. **Version control** — keep `~/.gent/init.janet` in dotfiles repo
6. **Project configs** — use `.gent/init.janet` for project-specific settings only
7. **Hot-reload widgets** — after registering widgets or changing layouts in a live session, use `(widget/mark-all-dirty)` to trigger a re-render

## Getting Help

- `/tools` — list available tools
- `/hooks` — list active hooks
- `/skills` — list available skills
- `/config` — show API configuration
- `eval_janet` tool — test Janet code interactively
