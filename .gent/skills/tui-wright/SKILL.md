---
name: tui-wright
description: Operate gent programmatically via tui-wright — spawning sessions, sending input, reading screens, profiling, and recording demos
---

# Operating gent with tui-wright

[tui-wright](https://github.com/pepegar/tui-wright) spawns gent in a virtual terminal so you can send keyboard/mouse input and read the screen programmatically.

## Spawning a session

```sh
tui-wright spawn bash --cols 100 --rows 30
# → session: abc123

tui-wright type abc123 " cd /path/to/gent && ./target/debug/gent"
tui-wright key abc123 enter
sleep 3
```

**Important:** The tui-wright daemon runs from `$HOME`. Always `cd` to the gent project root first, or use absolute paths. Prefix the `cd` with a space so it doesn't save in shell history.

## Sending input

```sh
# Type text into the editor
tui-wright type abc123 "Hello, what is 2+2?"

# Press keys
tui-wright key abc123 enter
tui-wright key abc123 ctrl+c
tui-wright key abc123 down

# Mouse events
tui-wright mouse abc123 scrollup 50 15
tui-wright mouse abc123 scrolldown 50 15
```

## Reading the screen

```sh
tui-wright screen abc123
```

## Timing

Add `sleep` between actions — gent needs time to process input and redraw:
- **0.2–0.5s** after key/mouse events
- **2–3s** after launching gent or submitting a prompt
- **Longer** for streaming LLM responses

Scroll events are coalesced by gent's reactor — rapid bursts are batched into fewer dispatches.

## Cleanup

```sh
tui-wright key abc123 ctrl+c
sleep 1
tui-wright kill abc123
```

---

## Profiling

Launch gent with profiling enabled:

```sh
tui-wright type abc123 " cd /path/to/gent && GENT_PROFILE=1 ./target/debug/gent"
tui-wright key abc123 enter
sleep 3
```

After interacting, collect profiling data:

```sh
# Print stats table
tui-wright type abc123 "/profile stats"
tui-wright key abc123 enter
sleep 0.5

# Scroll to see output
for i in $(seq 1 500); do tui-wright mouse abc123 scrolldown 50 15; done
sleep 1
tui-wright screen abc123

# Export Chrome Trace Event JSON
tui-wright type abc123 "/profile dump"
tui-wright key abc123 enter
sleep 0.5
```

Profile traces are saved to `.gent/profile-<timestamp>.json` and can be opened in [speedscope.app](https://speedscope.app) for flame-graph visualization (`reactor:loop` → `render:frame` → `render:chat`, etc.).

### Key profiling spans

| Span | Category | What it measures |
|------|----------|-----------------|
| `reactor:loop` | reactor | One full iteration of the event loop |
| `event:poll` | io | Blocking wait for terminal event (includes idle time) |
| `event:scroll` | event | Scroll event coalescing and dispatch |
| `event:key` | event | Key event batching and dispatch |
| `render:frame` | render | Full frame render (widget renders + diff + ANSI emission) |
| `render:chat` | render | Chat widget render into buffer |
| `render:editor` | render | Editor widget render |
| `render:separator` | render | Separator widget render |
| `stream:api-call` | stream | LLM API streaming call (wall clock) |
| `stream:drain` | stream | Reading chunks from the HTTP stream |
| `widget:update-all` | update | Per-frame widget polling (chat drains stream, polls tools) |
| `tool:*` | tool | Individual tool execution (auto-instrumented via hooks) |

---

## Recording demos with stage mode

Stage mode lets you script fake LLM responses for reproducible demo recordings without real API calls.

### Stage mode basics

`boot.janet` checks the `GENT_STAGE` env var:

```sh
# Pure stage mode (responses default to "(no response queued)")
GENT_STAGE=1 ./target/debug/gent

# Stage mode with a script that pre-queues responses
GENT_STAGE=/path/to/demo.janet ./target/debug/gent
```

The script runs before `(agent/run)`, so queued responses are ready when the reactor starts.

### Writing a stage script

```janet
(import core/stage :as stage)

# Simple text response
(stage/respond (stage/text "Hello! I'm gent."))

# Streaming text (token-by-token, shows the spinner)
(stage/respond (stage/text-stream "This streams slowly..." :token-delay 0.05))

# Thinking then text (shows spinner during thinking phase)
(stage/respond (stage/thinking-then-text
  "Let me reason about this..."
  "Here is my answer."))

# Tool call (triggers tool execution, needs a follow-up response)
(stage/respond (stage/tool-call "prompt_user"
  {:type "select" :title "Pick one" :options [{:label "A"} {:label "B"}]}
  :id "toolu_1"))
(stage/respond (stage/text "You picked a good one!"))

# Bulk queue
(stage/sequence [(stage/text "First") (stage/text "Second")])
```

Responses are FIFO — queue them in conversation order. Each user submit pops the next response. Tool calls that return results trigger another API call, so queue a follow-up for each.

### Recording with tui-wright trace

tui-wright has built-in asciicast v2 recording via `tui-wright trace start/stop`:

```sh
#!/usr/bin/env bash
set -euo pipefail

CAST="/tmp/demo.cast"
PROJECT="/path/to/gent"

SESSION=$(tui-wright spawn bash --cols 100 --rows 30 2>&1 | grep -oE '[a-f0-9]+$')

tui-wright trace start "$SESSION" --output "$CAST"
sleep 0.5

tui-wright type "$SESSION" " cd $PROJECT && GENT_STAGE=/tmp/demo.janet ./target/debug/gent"
tui-wright key "$SESSION" enter
sleep 3

tui-wright type "$SESSION" "Hello, what can you do?"
sleep 0.5
tui-wright key "$SESSION" enter
sleep 4

# Navigate a dialog (if one appears)
tui-wright key "$SESSION" down
sleep 0.3
tui-wright key "$SESSION" enter
sleep 3

tui-wright key "$SESSION" ctrl+c
sleep 1
tui-wright trace stop "$SESSION"
tui-wright kill "$SESSION" 2>/dev/null || true
```

### Uploading

```sh
asciinema upload /tmp/demo.cast
```

Note: asciinema.org has a file size limit. Keep demos short (under 30s) to stay well under it.

### Tips

- **`thinking-then-text`** is the best way to show the spinner — the thinking phase takes visible time before text appears.
- **Tool calls with `prompt_user`** show the dialog overlay — use `tui-wright key` for arrow navigation and enter to select.
