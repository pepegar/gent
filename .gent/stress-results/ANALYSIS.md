# Rendering Stress Test Analysis

## Test Environment
- Machine: macOS Darwin 25.2.0
- Build: debug (unoptimized)
- tui-wright: virtual terminal, programmatic input
- Stage mode: scripted LLM responses, no network

## Baseline Results (before optimizations)

| Test | Terminal | Frames | render:frame avg | render:chat avg | Diff cost | Max frame |
|------|----------|--------|-----------------|----------------|-----------|-----------|
| Scroll (alternating) | 100x30 | 102 | **0.9ms** | 0.3ms | 0.6ms (67%) | 4.9ms |
| Scroll (alternating) | 200x50 | 102 | **2.8ms** | 0.9ms | 1.9ms (68%) | 9.9ms |
| Markdown streaming | 100x30 | 419 | **1.5ms** | 0.3ms | 1.2ms (80%) | 3.6ms |
| Markdown streaming | 200x50 | 359 | **4.7ms** | 0.6ms | 4.1ms (87%) | 7.3ms |
| Resize cycling | mixed | 1128 | **2.7ms** | 0.4ms | 2.3ms (85%) | **13.4ms** |

## After Optimizations

| Test | Terminal | render:frame avg | Diff cost | Change |
|------|----------|-----------------|-----------|--------|
| Scroll (alternating) | 100x30 | **0.5ms** | 0.2ms | **-44%** |
| Scroll (alternating) | 200x50 | **1.4ms** | 0.4ms | **-50%** |
| Markdown streaming | 100x30 | **1.4ms** | 0.5ms | **-7%** |
| Markdown streaming | 200x50 | **2.5ms** | 1.2ms | **-43%** |

## Optimizations Applied

### 1. Buffer reuse (`buffer-clear` instead of re-allocation)
- **Impact**: Eliminated 10K+ table allocations per frame at 200x50
- **Files**: `janet/tui/buffer.janet` (added `buffer-clear`), `janet/core/agent.janet` (added `widget-bufs` cache)
- Scroll diff cost 200x50: 1.9ms → 0.4ms (**-79%**)

### 2. Rolling visual-row count
- **Impact**: Made scroll events O(1) instead of O(N) for 500+ scrollback lines
- **Files**: `janet/widgets/chat.janet` (cached `total-visual-rows`, incremental updates in `push-line`/`push-raw-line`)

### 3. Render-scrollback reverse elimination
- **Impact**: Eliminated `(reverse visual-rows)` allocation each frame
- **Files**: `janet/widgets/chat.janet` (render bottom-to-top using index math)

### 4. Cell aliasing fix in scroll-region-optimize
- **Impact**: Fixed a latent bug where scroll-region-optimize copied cell references instead of values. This caused cell corruption when the Rust diff updated aliased cells in prev-buf.
- **Files**: `janet/core/agent.janet` (copy `:ch`/`:style` values instead of table references)

### 5. Streaming dirty-row optimization
- **Impact**: During streaming, only the partial line (1 row) and spinner (3 rows) change per frame. After rendering, dirty-rows for stable scrollback rows are set to false, so the Rust diff skips them entirely.
- **Files**: `janet/widgets/chat.janet` (added `scrollback-dirty` flag, `prev-y-offset` tracking, dirty-row manipulation in `render-scrollback`)
- **Safety**: Only activates when scrollback hasn't changed AND visual layout (y-offset) is stable. Falls back to full-dirty on scrollback commits, layout changes, or non-streaming modes.
- Streaming diff cost 200x50: 3.7ms → 1.2ms (**-68%**)
- Streaming frame time 200x50: 4.4ms → 2.5ms (**-43%**)

## Key Findings

### Diff cost dominated streaming (87% → 48% of frame time)
Before optimization #5, the Rust diff processed all 10K cells (200×50) every frame during streaming, even though only the partial line changed. The dirty-row optimization reduced this to ~800 cells (4 rows × 200 cols) on frames without new scrollback commits. On frames where new lines are committed (~28% of frames), the full diff still runs.

### Buffer reuse is the biggest win for scroll
Reusing per-widget buffers avoids 10K table allocations per frame. Combined with scroll-region-optimize (which makes most rows in prev-buf match the new frame), the diff can skip most cells. This produced the largest improvement: 50% reduction in frame time at 200x50.

### Remaining optimization opportunity
The render-scrollback function still re-renders ALL visible rows every frame (even when only the partial line changed), contributing ~1.3ms per frame. A future retained-mode approach could skip re-rendering stable scrollback rows entirely, potentially cutting render:chat to near-zero on most streaming frames. This would require tracking which scrollback lines are visible and skipping their rendering when unchanged.

### Linear scaling with cell count
Performance scales linearly with terminal area. The 200x50 benchmark is consistently ~3x slower than 100x30, matching the 3.3x cell count ratio.
