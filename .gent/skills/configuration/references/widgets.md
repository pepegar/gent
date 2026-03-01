# Widget System

Gent uses a widget-based TUI (Terminal User Interface) built on a rendering pipeline with double-buffering and efficient diffing.

## Core Architecture

The UI consists of three main components:

1. **Reactor Loop** (`janet/core/agent.janet`) — Event polling, dispatching, and rendering
2. **Widget System** (`janet/core/widget.janet`) — Component registration, layout, and event handling
3. **Buffer System** (`janet/tui/buffer.janet`) — Screen rendering and diffing

## Default Layout

Gent's default layout is a 3-row vertical split:

```
┌─────────────────────────────────┐
│ Chat Widget (scrollable)        │ :fill space
│                                 │
├─────────────────────────────────┤
│ Separator Widget (status bar)   │ 1 row
├─────────────────────────────────┤
│ Editor Widget (input area)      │ dynamic height
└─────────────────────────────────┘
```

## Built-in Widgets

- **`:chat`** — Conversation display with markdown rendering, scrollback
- **`:separator`** — Status bar showing session info
- **`:editor`** — Multi-line text input with syntax highlighting

## Widget Structure

Every widget is a Janet table with these keys:

```janet
@{:name      :my-widget          # Unique identifier (keyword)
  :state     @{...}              # Widget's private state
  :rect      {:x 0 :y 0 :width 80 :height 24}  # Screen area (set by layout)
  :dirty     true                # Needs re-render?
  :focused   false               # Receives keyboard input?
  :tasks     @[]                 # Background task IDs
  :timers    @[]                 # Timer callbacks

  # Functions
  :render    (fn [self rect buf] ...)  # Draw to buffer
  :handle    (fn [self event] ...)     # Handle events
  :update    (fn [self] ...)           # Per-frame polling (optional)}
```

## Creating Custom Widgets

Here's a complete example of a simple clock widget:

```janet
# ~/.gent/widgets/clock.janet
(import core/widget :as widget)
(import tui)

(defn create-clock []
  @{:name :clock
    :state @{:last-update 0}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[{:interval-ms 1000  # Update every second
               :callback (fn [self] (put self :dirty true))}]

    :render (fn [self rect buf]
              (def now-str (os/date :nil (os/time)))
              (def x (+ (rect :x) (- (rect :width) (length now-str))))
              (tui/buffer-set-string buf x (rect :y) now-str
                                     (tui/style :fg :cyan :bold true)))

    :handle (fn [self event]
              # Clock doesn't handle any events
              nil)})

# Register the widget (call from ~/.gent/init.janet)
(widget/register (create-clock))
```

## Custom Layouts

Override the default layout with your own:

```janet
(import core/widget :as widget)

# Simple 2-pane layout
(widget/set-layout-data
  @[{:constraint 1  # Status bar at top
     :children [{:widget :separator :constraint :fill}]}
    {:constraint :fill  # Split remaining space
     :children [{:widget :chat :constraint 0.7}      # 70% for chat
                {:widget :clock :constraint :fill}]}   # 30% for clock
    {:widget :editor :constraint 5}])                 # 5 rows for input
```

Function-based layouts for dynamic sizing:

```janet
(widget/set-layout-fn
  (fn [area]
    (def third (math/floor (/ (area :width) 3)))
    @{:chat (tui/rect 0 0 (* third 2) (- (area :height) 6))
      :clock (tui/rect (* third 2) 0 third (- (area :height) 6))
      :separator (tui/rect 0 (- (area :height) 6) (area :width) 1)
      :editor (tui/rect 0 (- (area :height) 5) (area :width) 5)}))
```

## Layout Constraints

The layout system supports several constraint types:

```janet
# Fixed size (integer)
{:widget :separator :constraint 1}        # Exactly 1 row

# Percentage of remaining space (float 0.0-1.0)
{:widget :sidebar :constraint 0.2}        # 20% of width

# Take all leftover space
{:widget :main :constraint :fill}

# Dynamic sizing (function)
{:widget :editor :constraint |(editor/get-height)}

# Horizontal groups
{:constraint :fill
 :children [{:widget :left :constraint 40}   # 40 columns
            {:widget :right :constraint :fill}]}  # Rest of width
```

## Event Handling

Widgets can handle different event types:

```janet
:handle (fn [self event]
          (def type (event :type))
          (case type
            :key
            (do
              (def key (event :key))
              (case key
                "q" :quit                    # Return signal
                "r" (put self :dirty true)   # Mark for re-render
                nil))                        # No action

            :mouse
            (do
              (def btn (event :button))
              (def x (event :x))
              (def y (event :y))
              # Handle mouse click...
              )

            :scroll-up
            (do
              # Handle scroll...
              )

            # Custom events from other widgets
            :refresh-data
            (do
              # Refresh widget data...
              (put self :dirty true))

            nil))  # Default: no handling
```

## Buffer Rendering

Widgets render into a `tui/buffer` using these functions:

```janet
:render (fn [self rect buf]
          # Draw individual characters
          (tui/buffer-set-char buf x y "★" (tui/style :fg :yellow))

          # Draw strings
          (tui/buffer-set-string buf x y "Hello World" (tui/style :bold true))

          # Draw with word wrapping
          (tui/buffer-set-wrapped buf x y width "Long text..." style)

          # Draw rectangles
          (tui/buffer-fill-rect buf rect " " (tui/style :bg :blue))

          # Draw borders
          (tui/buffer-draw-border buf rect (tui/style :fg :gray)))
```

## Widget Communication

Use the pub/sub system for inter-widget communication:

```janet
(import core/widget :as widget)

# Publisher widget
(widget/publish :data-updated {:count 42})

# Subscriber widget
(widget/subscribe :data-updated
  (fn [data]
    (printf "Got update: %s" (data :count))
    (put my-widget :dirty true)))  # Trigger re-render
```

## Focus Management

Control which widget receives keyboard input:

```janet
# In your config or another widget's handler
(import core/widget :as widget)

# Focus a specific widget
(widget/focus :my-widget)

# Check which widget has focus
(def focused-widget (widget/focused))

# In your widget's render function, show focus state
:render (fn [self rect buf]
          (def focused? (self :focused))
          (def border-style (if focused?
                              (tui/style :fg :cyan :bold true)
                              (tui/style :fg :gray)))
          (tui/buffer-draw-border buf rect border-style))
```

## Widget Lifecycle

```janet
# Registration (usually in config or widget file)
(widget/register my-widget)

# Layout assignment (automatic on resize/startup)
# Widget's :rect is set by the layout system

# Event loop (automatic)
# 1. :update called each frame (if defined)
# 2. :handle called when events occur
# 3. :render called when :dirty is true

# Cleanup
(widget/unregister :my-widget)
```

## Debugging Widgets

Use these techniques to debug widget issues:

```janet
# Add debug rendering
:render (fn [self rect buf]
          # Show widget bounds
          (tui/buffer-draw-border buf rect (tui/style :fg :red))
          # Show coordinates
          (tui/buffer-set-string buf (rect :x) (rect :y)
                                 (string/format "(%d,%d)" (rect :x) (rect :y))
                                 (tui/style :fg :yellow))
          # Regular rendering...
          )

# Log events
:handle (fn [self event]
          (printf "Widget %s got event: %q" (self :name) event)
          # Handle event...
          )

# Force re-render for testing
(widget/mark-dirty :my-widget)
(widget/mark-all-dirty)  # Force full redraw
```

## Hot-Reloading Widgets

After registering new widgets or changing layouts in a live session, trigger a re-render to ensure changes are visible:

```janet
# After registering a new widget or modifying layout
(import core/widget :as widget)
(widget/mark-all-dirty)  # Force full redraw with new layout
```

This is especially useful when testing widget code with `eval_janet` — you can register widgets, change layouts, and immediately see the results without restarting gent.

## More Examples

See the main configuration guide for additional widget examples including status widgets, mini terminals, and custom layout managers.
