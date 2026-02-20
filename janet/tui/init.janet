# tui/init.janet — Janet TUI library, inspired by ratatui.
#
# A composable, buffer-based terminal UI library.
#
# Core types:
#   rect     — positioned rectangle on screen
#   style    — fg/bg color + modifiers (bold, italic, etc.)
#   buffer   — 2D cell grid (render target)
#
# Widgets (anything with a :render method):
#   text     — styled text (spans, lines)
#   block    — borders + padding + title container
#
# Layout:
#   vsplit   — stack rects vertically
#   hsplit   — stack rects horizontally
#
# Rendering pipeline:
#   1. Create a buffer for your terminal area
#   2. Render widgets into the buffer
#   3. Convert buffer to ANSI with buffer->str
#
# Example:
#   (import tui)
#   (def area (tui/rect 0 0 60 20))
#   (def buf (tui/buffer area))
#   (def blk (tui/block :title "Hello" :borders :all :border-type :rounded))
#   (tui/render blk area buf)
#   (def inner (tui/block-inner blk area))
#   (tui/render (tui/text "World!" :style (tui/style :fg :green)) inner buf)
#   (prin (tui/buffer->str buf))

# Import all sub-modules
(use ./rect)
(use ./style)
(use ./buffer)
(use ./text)
(use ./block)
(use ./layout)
(use ./widget)

# Re-export: (use ...) marks bindings as :private, so undo that
# for all non-internal symbols so (import tui) works.
(eachp [k v] (curenv)
  (when (and (symbol? k) (table? v) (get v :private))
    (put v :private false)))
