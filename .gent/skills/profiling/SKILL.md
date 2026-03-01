---
name: profiling
description: Use this skill when profiling gent's rendering performance, investigating frame time regressions, running scroll/streaming benchmarks with tui-wright, interpreting profiling stats, or planning rendering optimizations. Use when the user asks to "profile gent", "benchmark rendering", "measure frame time", "check FPS", "optimize rendering", or anything related to gent's performance measurement and tuning.
---

# Profiling Gent's Rendering Performance

Gent has a built-in span-based profiling system (`janet/core/profile.janet`) that records Chrome Trace Event JSON for flame-graph visualization in speedscope.app.

## Enabling Profiling

```bash
# Via environment variable (auto-enables on boot)
GENT_PROFILE=1 cargo run

# Or toggle during a session with slash commands
/profile start
/profile stop
```

## Collecting Data

During a session:
- `/profile stats` — formatted table of per-operation timings (count, total, avg, min, max)
- `/profile dump` — export Chrome Trace Event JSON to `.gent/profile-<timestamp>.json`
- `/profile reset` — clear all data (useful to isolate a specific interaction)

## Key Profiling Spans

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

## Interpreting Results

The key metric is **`render:frame` average** — this is the total time for one frame (widget render + diff + ANSI emission). To hit 60fps, it must stay under **16.7ms**.

Break down frame time as:
```
render:frame = render:chat + render:editor + render:separator + diff_cost
diff_cost    = render:frame - sum(render:widget spans)
```

### What to look for

- **`render:frame` avg > 8ms** — frames are heavy, scroll will feel sluggish
- **`render:chat` dominates** — widget rendering is the bottleneck (visual row computation, word wrapping)
- **Large diff cost** (frame minus widget sum) — the cell-by-cell diff or ANSI emission is slow
- **Many frames with 0ms render:chat** — dirty tracking is working (clean frames skip diff entirely)

## Automated Benchmarking with tui-wright

Use tui-wright to run reproducible scroll/streaming benchmarks in a virtual terminal.

### Scroll Benchmark

```bash
#!/usr/bin/env bash
set -euo pipefail

PROJECT="/Users/pepe/projects/github.com/pepegar/gent"
STAGE_SCRIPT="/tmp/profile-stage.janet"

# Create a stage script that generates enough content to scroll
cat > "$STAGE_SCRIPT" << 'JANET'
(import core/stage :as stage)
(stage/respond (stage/text-stream
  (string/join (seq [i :range [0 200]] (string "Line " i ": Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore.")) "\n")
  :token-delay 0.001))
JANET

# Spawn session
SESSION=$(tui-wright spawn bash --cols 100 --rows 30 2>&1 | grep -oE '[a-f0-9]+$')

# Launch gent in stage mode with profiling
tui-wright type "$SESSION" " cd $PROJECT && GENT_PROFILE=1 GENT_STAGE=$STAGE_SCRIPT ./target/debug/gent"
tui-wright key "$SESSION" enter
sleep 3

# Submit a prompt to trigger the staged response
tui-wright type "$SESSION" "Generate a long response"
tui-wright key "$SESSION" enter
sleep 5

# Reset profiling to isolate scroll events
tui-wright type "$SESSION" "/profile reset"
tui-wright key "$SESSION" enter
sleep 1

# Scroll up and down rapidly
for i in $(seq 1 50); do
  tui-wright mouse "$SESSION" scrollup 50 15
done
sleep 1
for i in $(seq 1 50); do
  tui-wright mouse "$SESSION" scrolldown 50 15
done
sleep 1

# Collect stats
tui-wright type "$SESSION" "/profile stats"
tui-wright key "$SESSION" enter
sleep 0.5
for i in $(seq 1 500); do tui-wright mouse "$SESSION" scrolldown 50 15; done
sleep 1
tui-wright screen "$SESSION"

# Export trace
tui-wright type "$SESSION" "/profile dump"
tui-wright key "$SESSION" enter
sleep 0.5

# Clean up
tui-wright key "$SESSION" ctrl+c
sleep 1
tui-wright kill "$SESSION"
```

### Streaming Benchmark

Same setup, but instead of scrolling, let the stage script stream and measure frame times during streaming:

```bash
# Reset profiling, send another prompt, wait for streaming to finish
tui-wright type "$SESSION" "/profile reset"
tui-wright key "$SESSION" enter
sleep 0.5
tui-wright type "$SESSION" "Another prompt"
tui-wright key "$SESSION" enter
sleep 10  # wait for streaming to complete
tui-wright type "$SESSION" "/profile stats"
tui-wright key "$SESSION" enter
```

## Rendering Pipeline Architecture

The rendering pipeline in `agent.janet` (`render-frame` function) works as follows:

1. **Full-screen buffer** created from `screen-area`
2. **Dirty widgets** render into their rect within a per-widget `small-buf` (with dirty-row tracking)
3. **Scroll region optimization** — for scroll events, the terminal shifts content natively via `\x1b[top;bottom r` + scroll sequences, then only the N new rows are diffed
4. **Native Rust diff** (`buffer/diff`) compares `prev-buf` vs `small-buf` cell-by-cell, skipping clean rows via `:dirty-rows`
5. **ANSI emission** — changed cells are written with cursor moves + SGR + chars
6. **Buffer swap** — `prev-buf` is updated in-place for next frame

### Optimization Stack (cumulative)

| Layer | What it does | Where |
|-------|-------------|-------|
| **Style interning** | Precomputed `:_sgr` strings on style structs; `style=` compares strings instead of `deep=` | `janet/tui/style.janet` |
| **Native Rust diff** | Cell-by-cell diff loop in compiled Rust instead of Janet interpreter | `src/native/buffer.rs` |
| **Dirty-row tracking** | Skip unchanged rows in diff; buffers track which rows were written to | `janet/tui/buffer.janet`, `src/native/buffer.rs` |
| **Terminal scroll regions** | Let terminal shift content natively on scroll; only diff N new rows | `janet/core/agent.janet` |
| **Visual row caching** | Cache `line-to-visual-rows` results on scrollback entries by width | `janet/widgets/chat.janet` |

### Performance Baseline and Targets

Measured on 100x30 terminal with tui-wright:

| Metric | Baseline | Current (all optimizations) |
|--------|----------|---------------------------|
| `render:frame` avg (scroll) | 12.6ms | 2.1ms |
| `render:frame` avg (streaming) | ~12ms | 1.4ms |
| Diff cost (frame - chat) | 10.5ms | 0.7ms |
| `render:chat` avg | 2.1ms | 1.4ms |
| Effective scroll FPS | 23fps | >60fps |

## Flame Graph Visualization

Export a trace and open it in speedscope:

```bash
# During session
/profile dump
# → writes .gent/profile-<session>.json

# Open in browser
open https://speedscope.app
# Drag and drop the JSON file
```

The trace uses Chrome Trace Event "X" (complete) format. In speedscope, the "Left Heavy" view shows aggregate time per span, while "Sandwich" view shows callers/callees for a selected span.

## Key Files

| File | Role |
|------|------|
| `janet/core/profile.janet` | Profiling system: `begin`/`end`/`with-span`, stats, Chrome Trace export |
| `janet/core/agent.janet` | Reactor loop and `render-frame` — the main profiling target |
| `janet/widgets/chat.janet` | Chat widget render, visual row caching |
| `janet/tui/style.janet` | Style interning (`style=`, `:_sgr` precomputation) |
| `janet/tui/buffer.janet` | Buffer creation, dirty-row tracking |
| `src/native/buffer.rs` | Native Rust `buffer/diff` implementation |

## Adding New Profiling Spans

Wrap any code section with `profile/with-span`:

```janet
(import core/profile :as profile)

(profile/with-span "my-operation" "category"
  (fn [] (do-expensive-thing)))
```

For spans with metadata:

```janet
(profile/with-span-meta "my-operation" "category"
  @{:items (length items) :width w}
  (fn [] (do-expensive-thing)))
```

Categories used: `"render"`, `"event"`, `"io"`, `"reactor"`, `"stream"`, `"update"`, `"tool"`.

## Common Investigations

### "Scroll feels sluggish"
1. `GENT_PROFILE=1 cargo run`, scroll around, `/profile stats`
2. Check `render:frame` avg — should be under 8ms for smooth 60fps
3. If diff cost (frame - chat) is high, check if `buffer/diff` is being called (native) vs Janet fallback
4. If `render:chat` is high, check visual row cache hit rate by adding a span around the cache lookup

### "Streaming is choppy"
1. Profile during streaming, check `render:frame` avg
2. Many frames should show 0ms (clean frames with no dirty widgets)
3. If most frames are dirty, check what's marking widgets dirty unnecessarily
4. `widget:update-all` shows polling cost — should be near 0ms when no tool results pending

### "Frame time regression after code change"
1. `git stash` your changes, profile baseline with tui-wright scroll benchmark
2. `git stash pop`, profile again with same benchmark
3. Compare `render:frame` and `render:chat` averages
4. Use `/profile dump` + speedscope to find which span grew
