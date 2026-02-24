# Rendering Performance Optimization Plan

## Context

Profiling with `GENT_PROFILE=1` and tui-wright interactive testing revealed that `render:frame` averages **12.6ms during scroll** (76% of the 16.7ms budget for 60fps). The cell-by-cell diff in Janet consumes **83% of frame time** (10.5ms), using `deep=` on style structs at ~3.2μs/cell × 2900 cells. Even during streaming, the diff takes 8.7ms. Effective scroll FPS is 23.

### Profiling Data (scroll-only test, 100×30 terminal)

```
Flame graph per reactor loop during scroll:

  reactor:loop             avg  26.35ms  (100%)
    ├─ event:poll               avg  13.61ms  (51.7%)  ████████████████████████
    ├─ render:frame (diff)      avg  10.57ms  (40.1%)  ████████████████████
    ├─ render:chat              avg   2.12ms  ( 8.1%)  ████
    ├─ event:scroll             avg   0.01ms  ( 0.0%)
    └─ widget:*                 avg   0.00ms  ( 0.0%)

  render:frame breakdown:
    ├─ render:chat (widget render):  avg 2.12ms
    └─ diff + ANSI emission:        avg 10.53ms  (83% of frame)

  Per-cell diff cost: ~3.2μs × 2900 cells = ~9.3ms
  Heavy frames (>8ms): 99% of all scroll frames
  Effective FPS: 23fps
```

### Root Cause

The diff loop at `agent.janet:116-137` does for each of ~2900 cells:
1. `buffer-get prev-buf x y` — bounds check + index calc (~0.5μs)
2. `buffer-get small-buf x y` — bounds check + index calc (~0.5μs)
3. `= (old :ch) (new :ch)` — string comparison (~0.2μs)
4. `deep= (old :style) (new :style)` — struct traversal (~2.0μs)

`deep=` on style structs is the dominant cost. It recursively compares nested structures like `{:fg [:rgb 137 180 250] :bold true}`.

---

## Phase 1: Style Interning (precomputed SGR strings)

**Goal**: Replace `deep=` style comparison with fast string `=` on precomputed SGR.

**Files to modify**:
- `janet/tui/style.janet` — style creation, `style-merge`, new `style=`
- `janet/tui/buffer.janet` — replace `deep=` in `buffer-diff`, `buffer->str`, `buffer->rows`
- `janet/core/agent.janet` — replace `deep=` in inline diff loop (lines 124, 129) and popup overlay (line 156)

**Changes**:

1. Extract the body of `style->sgr` into a private `style->sgr-raw` helper
2. Modify `style` (line 59-63) to append `:_sgr (style->sgr-raw raw)` to the struct
3. Update `style-default` (line 65-67) to `(struct :_sgr "")`
4. Update `style-merge` (line 69-86) to exclude `:_sgr` from merge keys, then append `:_sgr` on the result
5. Make `style->sgr` read from `:_sgr` when present, fall back to `style->sgr-raw`
6. Add `style=` function: checks `identical?` first, then compares `:_sgr` strings, falls back to `deep=`
7. Replace all `deep=` on styles with `tui/style=` in buffer.janet and agent.janet

**Expected impact**: Diff drops from 10.5ms to ~4-5ms (60% reduction in per-cell comparison cost).

### Phase 1 Measured Results (tui-wright, 100×30, scroll test)

```
Name                     Count  Total(ms)   Avg(ms)   Min(ms)   Max(ms)
render:frame                60      572.2       9.5       1.4      12.5
render:chat                 59      112.6       1.9       1.3       4.2
event:scroll                58        0.4       0.0       0.0       0.0

Diff cost (frame - chat):  ~7.6ms avg  (was 10.5ms → 28% reduction)
render:frame avg:           9.5ms      (was 12.6ms → 25% improvement)
render:chat avg:            1.9ms      (was 2.1ms  → similar)
Effective FPS:              ~37fps     (was 23fps)
```

Style interning helped but less than the optimistic estimate. The `style=` function using `=` on precomputed `:_sgr` strings is faster than `deep=`, but the Janet interpreter overhead for the full diff loop (buffer-get, index calc, function calls) still dominates.

---

## Phase 2: Native Rust Buffer Diff

**Goal**: Move the hot cell-by-cell diff loop from Janet to compiled Rust.

**Files to create/modify**:
- `src/native/buffer.rs` — **NEW** — native `buffer/diff` function
- `src/native/mod.rs` — register new module
- `janet/core/agent.janet` — replace 24-line Janet diff loop (lines 113-140) with `(buffer/diff prev-buf small-buf r)`

**`buffer/diff` signature**: `(buffer/diff old-buf new-buf rect)` → ANSI string

**Rust implementation**:
- Extract `:area` and `:cells` from both buffer tables
- For each cell in `rect`: compare `:ch` bytes and `:_sgr` strings (from Phase 1)
- Build output string with cursor moves + SGR + chars for changed cells
- Update old-buf cells in-place (matching existing behavior at agent.janet:137)
- Return ANSI string via `Janet::from(JanetString::new(...))`

**Integration in agent.janet**: The 24-line inline diff loop (lines 113-140) becomes:
```janet
(def diff-str (buffer/diff prev-buf small-buf r))
(when (not= "" diff-str) (term/write diff-str))
```

**Test compatibility**: Add a `buffer/diff` mock in `janet/test/fake-http.janet` that calls the existing Janet `tui/buffer-diff` so `janet janet/test/run.janet` continues to work without the Rust binary.

**Expected impact**: Per-cell cost drops from ~0.5μs (after Phase 1) to ~0.01-0.05μs. Total diff: under 0.3ms.

### Phase 2 Measured Results (tui-wright, 100×30, scroll test)

```
Name                     Count  Total(ms)   Avg(ms)   Min(ms)   Max(ms)
render:frame               100      487.4       4.9       0.4       7.2
render:chat                 99      247.0       2.5       1.6       4.5
event:scroll                98        0.6       0.0       0.0       0.0

Diff cost (frame - chat):  ~2.4ms avg  (was 7.6ms → 68% reduction)
render:frame avg:           4.9ms      (was 9.5ms → 48% improvement over Phase 1)
render:chat avg:            2.5ms      (was 1.9ms → slightly higher, likely noise)
Effective FPS:              ~56fps     (was 37fps)
Cumulative from baseline:   12.6ms → 4.9ms  (61% total reduction)
```

Moving the diff loop from Janet to compiled Rust eliminated the interpreter overhead (function call dispatch, keyword lookups, temporary allocations). The diff cost dropped from 7.6ms to 2.4ms. The remaining 2.4ms is dominated by Janet FFI boundary crossings (extracting cell tables, keyword lookups via janetrs). render:chat at 2.5ms is now the dominant cost — the widget render itself takes as long as the native diff.

---

## Phase 3: Row-level Dirty Tracking

**Goal**: Skip unchanged rows in the diff. During streaming, typically only 1-3 of ~24 rows change.

**Files to modify**:
- `janet/tui/buffer.janet` — add `:dirty-rows` tracking to buffers
- `src/native/buffer.rs` — read `:dirty-rows` and skip clean rows
- `janet/core/agent.janet` — create small-bufs with dirty tracking enabled

**Changes**:

1. Modify `buffer` constructor to accept optional `track-dirty` flag; when true, add `:dirty-rows` array (all `true` initially)
2. Modify `buffer-set-char`, `buffer-set-string`, `buffer-fill`, `buffer-set-style` to mark the affected row dirty
3. In Rust `buffer/diff`: check new-buf's `:dirty-rows`; skip rows where `dirty-rows[row] == false`
4. In agent.janet: create small-buf with `(tui/buffer r true)` for dirty tracking

**Expected impact**: During streaming, diff visits ~120-360 cells instead of 2900.

### Phase 3 Measured Results (tui-wright, 100×30)

**Scroll test:**
```
Name                     Count  Total(ms)   Avg(ms)   Min(ms)   Max(ms)
render:frame               102      535.5       5.2       0.5       7.6
render:chat                101      280.0       2.8       1.8       5.0
event:scroll               100        0.9       0.0       0.0       0.0

Diff cost (frame - chat):  ~2.4ms avg  (same as Phase 2)
render:frame avg:           5.2ms      (was 4.9ms → slight regression from tracking overhead)
render:chat avg:            2.8ms      (was 2.5ms → +0.3ms from buffer-set-char dirty marking)
```

**Streaming test:**
```
Name                     Count  Total(ms)   Avg(ms)   Min(ms)   Max(ms)
render:frame               355      761.1       2.1       0.0       7.5
render:chat                165      413.3       2.5       1.8       4.9

render:frame avg:           2.1ms      (was 4.9ms → 57% improvement during streaming)
Per-dirty-frame time:       ~4.6ms     (761.1 / 165 dirty frames)
Diff cost (dirty frames):   ~2.1ms     (4.6 - 2.5)
Effective streaming FPS:    >60fps     (most frames skip diff entirely)
```

During scroll, all rows change, so dirty tracking adds slight overhead (~0.3ms) with no benefit. During streaming, the real win appears: render:frame drops from 4.9ms to 2.1ms because ~54% of frames have no dirty widgets at all (diff returns instantly), and frames with dirty widgets only diff the 1-3 changed rows instead of all ~24.

---

## Phase 4: Terminal Scroll Regions

**Goal**: For scroll events, let the terminal shift content natively; only render the 1-2 new lines.

**Files to modify**:
- `janet/core/agent.janet` — add scroll-region rendering path in the scroll event handler
- `janet/widgets/chat.janet` — scroll handlers return metadata instead of just marking dirty

**Architecture** (Option C — cleanest separation of concerns):

1. Chat widget scroll handlers return `[:scroll-optimized actual-delta direction]` to agent.janet instead of just calling `mark-dirty`
2. Agent.janet intercepts this return value in the scroll dispatch (lines 299-324)
3. Agent.janet performs the scroll-region rendering:
   - Set scroll region: `\x1b[top;bottom r` covering the chat rect
   - Scroll: `\x1b[NS` (scroll up) or `\x1b[NT` (scroll down)
   - Reset region: `\x1b[r`
   - Shift cells in `prev-buf` (memmove-style array shift)
   - Render only the N new lines into prev-buf and terminal
   - Skip the normal render-frame for chat widget this frame
4. Fallback to full re-render when delta > half the viewport height

**Edge cases**:
- If completion popup was visible, fall back to full redraw
- If spinner is active, fall back to full redraw
- On resize, normal full redraw path handles it

**Expected impact**: Scroll rendering drops to O(width × N) where N = 1-3 new lines.

---

## Bonus: Visual Row Caching

**Goal**: Cache `line-to-visual-rows` results on scrollback entries.

**File**: `janet/widgets/chat.janet`

**Changes**:
1. Add `line-to-visual-rows-cached` wrapper that stores results on the scrollback entry with `:_cached-rows` and `:_cached-width`
2. On cache hit (same width), return cached result directly
3. Replace calls at lines 972 and 998 with cached version
4. No explicit invalidation needed: new entries start uncached, width changes invalidate via key mismatch

**Expected impact**: Saves ~0.5-1ms per frame in render:chat after first render of each visible line.

---

## Implementation Order

| Phase | Effort | Risk | Cumulative Frame Time |
|-------|--------|------|----------------------|
| 1. Style interning | Small | Low | ~5ms (from 12.6ms) |
| 2. Rust buffer diff | Medium | Medium | ~2ms |
| 3. Row-level dirty | Small | Low | ~1.5ms (streaming) |
| 4. Scroll regions | Medium | Higher | ~0.5ms (scroll) |
| 5. Visual row cache | Small | Very low | ~0.3ms |

## Verification

After each phase:
```sh
cargo build && janet janet/test/run.janet
```

After all phases, re-run the profiling test:
```sh
GENT_PROFILE=1 cargo run
# Interact, scroll, then /profile stats and /profile dump
# Open trace in https://speedscope.app
```

Target metrics:
- render:frame avg < 2ms during scroll
- render:frame avg < 1ms during streaming
- Effective FPS > 60 during scroll
