# Rendering & Scrolling Research

Investigation of gent's TUI rendering and scrolling behavior via programmatic
testing with tui-wright (120x40, 100x35, 80x24, 60x30 viewports).

## Bugs Found

### 1. Scroll-region optimization corrupts border cells

**Severity: High**
**File:** `janet/core/agent.janet:62-134` (`scroll-region-optimize`)

Terminal scroll regions (`\x1b[%d;%dr` + `\x1b[%dS`/`\x1b[%dT`) operate on
**full terminal lines** — they shift every column in the affected rows, including
the left and right border `│` characters drawn by `tui/block`. After scrolling,
the top or bottom rows inside the chat widget lose their border cells.

**Reproduction:** Scroll up with Page Up or mouse wheel. The top N rows
(where N = scroll delta) will be missing their left `│` border.

**Root cause:** `scroll-region-optimize` uses `(chat-w :content-rect)` for
row bounds, but the terminal scroll operation affects the full line width,
including the border columns at x=0 and x=width-1. The `prev-buf` cell
shift correctly handles the content rect columns (rx..rx+rw), but the
terminal itself shifts the border cells too, leaving them blank.

**Possible fixes:**
- Extend the prev-buf shift to cover the full terminal width (columns 0..pw),
  not just the content rect columns, so the diff re-paints borders.
- After the scroll region operation, invalidate the border columns in prev-buf
  so the diff will repaint them.
- Skip the optimization when the content rect doesn't span the full terminal
  width (i.e., when there are borders).

### 2. Rapid scroll coalescing causes severe rendering corruption

**Severity: High**
**File:** `janet/core/agent.janet:426-443` (scroll event coalescing)

When many scroll events arrive in a burst (e.g., fast trackpad flicking),
the coalesced delta can be large. Combined with the scroll-region-optimize
bug above, this produces severe artifacts: alternating blank/content rows,
duplicated content, and wholesale loss of borders across the entire chat area.

**Reproduction:** Send 20+ rapid `scrollup` events in quick succession.

**Root cause:** Multiple scroll-region-optimize calls may be applied in a
single frame, but `pending-scroll-opt` only tracks the last one. The
`prev-buf` state can drift arbitrarily far from the actual terminal state.

**Possible fix:** Cap the coalesced delta at a maximum (e.g., half the
viewport height) and fall back to a full redraw when exceeded. The guard
at line 77 (`(> delta (math/floor (/ rh 2)))`) exists but only checks the
per-call delta, not the cumulative effect.

### 3. Markdown tables break at narrow widths

**Severity: Medium**
**File:** `janet/widgets/chat.janet:375-467` (`line-to-visual-rows`)

Tables rendered by `tui/markdown.janet` produce lines with `│` box-drawing
characters as cell delimiters. When the terminal is narrower than the table
width, the word-wrap logic splits table rows mid-cell, producing visually
broken tables:

```
│▐         │ `janet/core/`     │ Core runtime (agent loop, tools, hooks,      │
│▐         etc.)      │                                                       │
```

The table border `│` characters wrap to random positions on the next line.
This was observed at 100, 80, and 60 column widths.

**Root cause:** Word-wrapping treats table lines like prose — it breaks at
spaces. But table lines are structurally rigid; breaking them at spaces
produces meaningless fragments.

**Possible fixes:**
- Detect table lines (those rendered by `render-table-line`) and apply
  horizontal scrolling or truncation instead of wrapping.
- Add a `:nowrap` flag to scrollback entries produced by table rendering,
  and truncate with `…` when they exceed the viewport width.
- Re-render tables at the current width when the viewport changes (would
  require storing the table data in the scrollback entry, not just the
  pre-rendered line).

## Enhancements

### 4. No scroll position indicator

There is no visual indication of scroll position. When scrolled up in a long
conversation, the user has no idea where they are relative to the bottom.

**Suggestions:**
- Show a scrollbar track in the right border of the chat widget (using
  `▐`, `█`, or half-block characters). Map `scroll-offset / total-visual-rows`
  to a thumb position within the border height.
- Show a "scroll: 42/318" counter in the chat border title when scrolled up.
- Show a "↓ N lines below" indicator at the bottom of the chat when scrolled
  up, like many terminal emulators do.

### 5. Row background colors defined but not applied

**File:** `janet/widgets/chat.janet:1609-1616`

The color themes define `*-row-bg` styles with background colors (e.g.,
`(tui/style :bg [:rgb 56 40 48])` for agent rows), but `render-scrollback`
only uses these keywords to choose the gutter `▐` marker color. The actual
background color is never applied to the row cells.

At the JSON cell level, all cells have `bg: {r:0, g:0, b:0}` regardless
of message type. The row-bg styles are essentially dead code.

**Suggestion:** After rendering the text content of each visual row, apply
the row background style to all cells in that row using `buffer-set-style`
or by including the bg color in each cell's style during rendering. This
would create the subtle color-banded effect the theme colors were designed
for (blue tint for user, peach for agent, green for tools).

### 6. No "snap to bottom" affordance

When the user scrolls up and new content arrives (agent response, tool output),
`push-line` and `push-raw-line` increment `scroll-offset` to keep the view
stable. This is correct behavior, but there is no quick way to jump back to
the bottom — the user must Page Down repeatedly or scroll back manually.

**Suggestions:**
- Auto-snap to bottom when the user presses Enter to send a new message
  (already happens since `scroll-offset` resets implicitly).
- Add a keybinding (e.g., `End` or `G` when chat is focused) to jump to
  bottom instantly (`(set scroll-offset 0)`).
- Show a floating "[↓ New content]" indicator when scrolled up and new
  content arrives below the viewport.

### 7. No smooth/animated scrolling

Scrolling is instantaneous — the viewport jumps N rows at once. While the
scroll-region-optimize attempts to use terminal hardware scrolling for
smooth appearance, the bugs above prevent this from working correctly.

**Suggestions:**
- Fix the scroll-region bugs first (items 1-2).
- Consider sub-line interpolation: when scrolling 1 line, render 2-3
  intermediate frames at 16ms intervals to create a smooth animation.
  This would leverage the existing 16ms poll timeout during streaming.

### 8. Editor status bar truncation at narrow widths

**File:** `janet/widgets/editor.janet:553-557`

The editor border title (e.g., `focus: editor │ 6 msgs ≈ 703 tokens │
20260306-193534-0001`) gets hard-truncated when the widget is too narrow,
cutting mid-text: `│ 2──────╮`. The truncation happens inside `block.janet`'s
`buffer-set-string` which just clips at the right border.

**Suggestion:** Prioritize the most important info in the title and use
ellipsis truncation. For example, at narrow widths show only `6 msgs ≈ 703t`
rather than trying to show the full session ID.

### 9. Table rendering could respect viewport width

**File:** `janet/tui/markdown.janet:178-187`

Tables are rendered at their natural width (sum of column widths + borders)
regardless of the available viewport width. The `compute-col-widths` function
uses the max width of each column's content.

**Suggestion:** Accept an optional `max-width` parameter. When the table
would exceed it, either:
- Truncate cells with `…` to fit within the available width.
- Switch to a vertical "key: value" layout for narrow viewports.
- Allow horizontal scrolling within the table region.

### 10. Gutter marker `▐` uses foreground color only

The gutter marker `▐` (right half block) is rendered with a foreground color
matching the message type but no background. This means the left half of the
gutter cell is always the terminal's default background. Using both fg and bg
(e.g., bg matching the row-bg and fg matching the label color) would create
a more polished two-tone gutter effect.

## Summary of Priority

| # | Issue | Type | Priority |
|---|-------|------|----------|
| 1 | Scroll-region border corruption | Bug | P0 |
| 2 | Rapid scroll rendering corruption | Bug | P0 |
| 3 | Table wrapping at narrow widths | Bug | P1 |
| 5 | Row backgrounds not applied | Enhancement | P1 |
| 4 | No scroll position indicator | Enhancement | P2 |
| 6 | No snap-to-bottom affordance | Enhancement | P2 |
| 8 | Status bar truncation | Enhancement | P2 |
| 9 | Tables don't respect viewport width | Enhancement | P2 |
| 10 | Gutter marker styling | Enhancement | P3 |
| 7 | Smooth scrolling | Enhancement | P3 |
