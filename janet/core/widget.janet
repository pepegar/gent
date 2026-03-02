# core/widget.janet — Widget protocol, registry, and layout management.
#
# The widget infrastructure for gent's TUI. Widgets are independent UI
# components with their own state, event handling, and rendering.
#
(import tui/layout :as tui-layout)
# Widget protocol:
#   :name     — keyword, unique identifier
#   :state    — mutable state table (widget owns this)
#   :rect     — screen area (set by layout manager)
#   :dirty    — boolean, true when state changed since last render
#   :render   — (fn [self rect buf] ...) renders into a tui/buffer
#   :handle   — (fn [self event] ...) processes event, returns value or nil
#   :update   — (fn [self] ...) per-frame polling (optional, for streaming/async)
#   :focused  — boolean, receives keyboard input when true
#   :tasks    — @[] of active background task IDs
#   :timers   — @[] of {:interval-ms :last-tick :callback}

# ── Registry ───────────────────────────────────────────────────

(var- widgets @{})
(var- widget-order @[])

(defn register
  "Register a widget with the system."
  [widget]
  (def name (widget :name))
  (put widgets name widget)
  (unless (find |(= $ name) widget-order)
    (array/push widget-order name))
  widget)

(defn unregister
  "Remove a widget by name."
  [name]
  (put widgets name nil)
  (def idx (find-index |(= $ name) widget-order))
  (when idx (array/remove widget-order idx)))

(defn get-widget
  "Get a widget by name, or nil."
  [name]
  (get widgets name))

(defn list-widgets
  "Return all registered widget names in render order."
  []
  (array/slice widget-order))

# ── Focus ──────────────────────────────────────────────────────

(var- focused-name nil)
(var- focus-neighbors @{})

(defn focus
  "Set which widget receives keyboard input."
  [name]
  (def old-name focused-name)
  (when focused-name
    (when-let [w (get widgets focused-name)]
      (put w :focused false)
      (put w :dirty true)))
  (set focused-name name)
  (when-let [w (get widgets name)]
    (put w :focused true)
    (put w :dirty true)))

(defn focused
  "Return the currently focused widget, or nil."
  []
  (when focused-name (get widgets focused-name)))

(defn- rect-overlaps-vertically?
  "Check if two rects share any vertical space."
  [r1 r2]
  (def r1-top (r1 :y))
  (def r1-bottom (+ (r1 :y) (r1 :height)))
  (def r2-top (r2 :y))
  (def r2-bottom (+ (r2 :y) (r2 :height)))
  (not (or (>= r1-top r2-bottom) (>= r2-top r1-bottom))))

(defn- rect-overlaps-horizontally?
  "Check if two rects share any horizontal space."
  [r1 r2]
  (def r1-left (r1 :x))
  (def r1-right (+ (r1 :x) (r1 :width)))
  (def r2-left (r2 :x))
  (def r2-right (+ (r2 :x) (r2 :width)))
  (not (or (>= r1-left r2-right) (>= r2-left r1-right))))

(defn- build-neighbor-graph
  "Build a spatial neighbor graph from widget rects.
   Returns @{:widget-name {:up :name :down :name :left :name :right :name} ...}
   Only includes focusable widgets."
  []
  (def graph @{})
  (def focusable-widgets @[])

  # Collect focusable widgets with rects
  (eachp [name widget] widgets
    (when (and widget (widget :rect) (not= false (get widget :focusable true)))
      (array/push focusable-widgets [name widget])))

  # For each widget, find neighbors in each direction
  (each [name widget] focusable-widgets
    (def rect (widget :rect))
    (def neighbors @{:up nil :down nil :left nil :right nil})

    # Find neighbor above (closest widget with bottom edge at or above our top edge)
    (var best-up nil)
    (var best-up-dist math/inf)
    (each [other-name other-widget] focusable-widgets
      (when (not= name other-name)
        (def other-rect (other-widget :rect))
        (def other-bottom (+ (other-rect :y) (other-rect :height)))
        (def our-top (rect :y))
        (when (and (<= other-bottom our-top)
                   (rect-overlaps-horizontally? rect other-rect))
          (def dist (- our-top other-bottom))
          (when (< dist best-up-dist)
            (set best-up other-name)
            (set best-up-dist dist)))))
    (put neighbors :up best-up)

    # Find neighbor below (closest widget with top edge at or below our bottom edge)
    (var best-down nil)
    (var best-down-dist math/inf)
    (each [other-name other-widget] focusable-widgets
      (when (not= name other-name)
        (def other-rect (other-widget :rect))
        (def other-top (other-rect :y))
        (def our-bottom (+ (rect :y) (rect :height)))
        (when (and (>= other-top our-bottom)
                   (rect-overlaps-horizontally? rect other-rect))
          (def dist (- other-top our-bottom))
          (when (< dist best-down-dist)
            (set best-down other-name)
            (set best-down-dist dist)))))
    (put neighbors :down best-down)

    # Find neighbor to left (closest widget with right edge at or before our left edge)
    (var best-left nil)
    (var best-left-dist math/inf)
    (each [other-name other-widget] focusable-widgets
      (when (not= name other-name)
        (def other-rect (other-widget :rect))
        (def other-right (+ (other-rect :x) (other-rect :width)))
        (def our-left (rect :x))
        (when (and (<= other-right our-left)
                   (rect-overlaps-vertically? rect other-rect))
          (def dist (- our-left other-right))
          (when (< dist best-left-dist)
            (set best-left other-name)
            (set best-left-dist dist)))))
    (put neighbors :left best-left)

    # Find neighbor to right (closest widget with left edge at or after our right edge)
    (var best-right nil)
    (var best-right-dist math/inf)
    (each [other-name other-widget] focusable-widgets
      (when (not= name other-name)
        (def other-rect (other-widget :rect))
        (def other-left (other-rect :x))
        (def our-right (+ (rect :x) (rect :width)))
        (when (and (>= other-left our-right)
                   (rect-overlaps-vertically? rect other-rect))
          (def dist (- other-left our-right))
          (when (< dist best-right-dist)
            (set best-right other-name)
            (set best-right-dist dist)))))
    (put neighbors :right best-right)

    (put graph name neighbors))

  graph)

(defn- find-wrap-target
  "Find a widget to wrap to when moving in direction with no direct neighbor.
   For toroidal wrapping: up wraps to bottom, down to top, etc."
  [current-name direction]
  (def current-widget (get widgets current-name))
  (when (nil? current-widget) (break nil))
  (def current-rect (current-widget :rect))
  (when (nil? current-rect) (break nil))

  (def focusable-widgets @[])
  (eachp [name widget] widgets
    (when (and widget (widget :rect) (not= false (get widget :focusable true))
               (not= name current-name))
      (array/push focusable-widgets [name widget])))

  (var best-target nil)
  (var best-metric nil)

  (case direction
    :up
    # Wrap to bottom: find widget with highest bottom edge
    (each [name widget] focusable-widgets
      (def rect (widget :rect))
      (def bottom (+ (rect :y) (rect :height)))
      (when (or (nil? best-metric) (> bottom best-metric))
        (set best-target name)
        (set best-metric bottom)))

    :down
    # Wrap to top: find widget with lowest top edge
    (each [name widget] focusable-widgets
      (def rect (widget :rect))
      (def top (rect :y))
      (when (or (nil? best-metric) (< top best-metric))
        (set best-target name)
        (set best-metric top)))

    :left
    # Wrap to right: find widget with highest right edge
    (each [name widget] focusable-widgets
      (def rect (widget :rect))
      (def right (+ (rect :x) (rect :width)))
      (when (or (nil? best-metric) (> right best-metric))
        (set best-target name)
        (set best-metric right)))

    :right
    # Wrap to left: find widget with lowest left edge
    (each [name widget] focusable-widgets
      (def rect (widget :rect))
      (def left (rect :x))
      (when (or (nil? best-metric) (< left best-metric))
        (set best-target name)
        (set best-metric left))))

  best-target)

(defn focus-direction
  "Move focus in a direction (:up :down :left :right) with toroidal wrapping.
   Returns the new focused widget name, or nil if no change."
  [direction]
  (when (nil? focused-name) (break nil))

  # Rebuild neighbor graph if empty or layout changed
  (when (empty? focus-neighbors)
    (set focus-neighbors (build-neighbor-graph)))

  (def current-neighbors (get focus-neighbors focused-name))
  (when (nil? current-neighbors) (break nil))

  (def target (get current-neighbors direction))
  (def final-target
    (if target
      target
      # No direct neighbor, try toroidal wrap
      (find-wrap-target focused-name direction)))

  (when final-target
    (focus final-target)
    final-target))

(defn rebuild-focus-graph
  "Force rebuild of the focus neighbor graph. Call after layout changes."
  []
  (set focus-neighbors (build-neighbor-graph)))

# ── Layout ─────────────────────────────────────────────────────

(var- layout-fn nil)
(var- layout-data nil)
(var- named-layouts @{})

(defn register-layout
  "Register a named layout (function or declarative data structure).
   Function signature: (fn [area] @{:widget-name rect ...})
   Data: array of row descriptors (see tui/layout resolve-layout)."
  [name layout]
  (put named-layouts name layout))

(defn set-layout
  "Switch to a named layout."
  [name]
  (def layout (get named-layouts name))
  (if (function? layout)
    (do (set layout-fn layout) (set layout-data nil))
    (do (set layout-data layout) (set layout-fn nil))))

(defn set-layout-fn
  "Set a custom layout function directly."
  [f]
  (set layout-fn f)
  (set layout-data nil))

(defn set-layout-data
  "Set a declarative layout data structure directly."
  [data]
  (set layout-data data)
  (set layout-fn nil))

(defn has-layout?
  "Return true if a layout function or data has been set."
  []
  (or (not (nil? layout-fn)) (not (nil? layout-data))))

(defn do-layout
  "Run the layout and assign rects to widgets.
   Returns the assignments table."
  [area]
  (def assignments
    (cond
      layout-data (tui-layout/resolve-layout layout-data area)
      layout-fn   (layout-fn area)
      nil))
  (when assignments
    (eachp [name rect] assignments
      (when-let [w (get widgets name)]
        (put w :rect rect)))
    # Rebuild focus graph after layout changes
    (rebuild-focus-graph)
    assignments))

# ── Timers ─────────────────────────────────────────────────────

(defn tick-timers
  "Fire any widget timers whose interval has elapsed."
  []
  (def now (* 1000 (os/clock)))
  (eachp [_ widget] widgets
    (when (and widget (widget :timers))
      (def timers (widget :timers))
      (for i 0 (length timers)
        (var timer (get timers i))
        # Auto-upgrade immutable structs to mutable tables
        (when (struct? timer)
          (set timer (table ;(kvs timer)))
          (put timers i timer))
        (def last (or (timer :last-tick) 0))
        (when (>= (- now last) (timer :interval-ms))
          (put timer :last-tick now)
          ((timer :callback) widget))))))

# ── Update ─────────────────────────────────────────────────────

(defn update-all
  "Call :update on all widgets that have it. For per-frame polling."
  []
  (each name widget-order
    (when-let [w (get widgets name)]
      (when (w :update)
        ((w :update) w)))))

# ── Rendering ──────────────────────────────────────────────────

(defn mark-dirty
  "Mark a widget as needing re-render."
  [name]
  (when-let [w (get widgets name)]
    (put w :dirty true)))

(defn mark-all-dirty
  "Mark all widgets as needing re-render."
  []
  (eachp [_ w] widgets
    (when w (put w :dirty true))))

(defn render-dirty
  "Render all dirty widgets. Calls :render with the widget's rect and buf.
   For Phase 1 hybrid rendering, buf may be nil — widgets that render
   directly to terminal (chat, editor) ignore it."
  [&opt buf]
  (each name widget-order
    (when-let [w (get widgets name)]
      (when (and (w :dirty) (w :rect) (w :render))
        ((w :render) w (w :rect) buf)
        (put w :dirty false)))))

# ── Event dispatch ─────────────────────────────────────────────

(defn dispatch
  "Send an event to a specific widget. Returns the :handle return value."
  [name event]
  (when-let [w (get widgets name)]
    (when (w :handle)
      ((w :handle) w event))))

(defn broadcast
  "Send an event to all widgets."
  [event]
  (each name widget-order
    (when-let [w (get widgets name)]
      (when (w :handle)
        ((w :handle) w event)))))

# ── Pub/Sub message bus ────────────────────────────────────────
# Simple publish/subscribe for inter-widget communication.

(var- subscriptions @{})

(defn subscribe
  "Subscribe to a topic. Callback: (fn [data] ...)"
  [topic callback]
  (unless (get subscriptions topic)
    (put subscriptions topic @[]))
  (array/push (get subscriptions topic) callback)
  topic)

(defn unsubscribe
  "Remove a callback from a topic."
  [topic callback]
  (when-let [subs (get subscriptions topic)]
    (var idx nil)
    (for i 0 (length subs)
      (when (= (get subs i) callback)
        (set idx i)))
    (when idx (array/remove subs idx))))

(defn publish
  "Publish data to all subscribers of a topic."
  [topic data]
  (when-let [subs (get subscriptions topic)]
    (each cb subs
      (try
        (cb data)
        ([err]
         (eprintf "Pub/sub error on %s: %s" (string topic) (string err)))))))

(defn list-topics
  "Return all topics that have subscribers."
  []
  (seq [[k v] :pairs subscriptions :when (not (empty? v))] k))

# ── Widget discovery ───────────────────────────────────────────
# Load widgets from ~/.gent/widgets/ and .gent/widgets/

(var- discovery-paths @[])

(defn init-widget-paths
  "Set up widget discovery paths."
  []
  (array/clear discovery-paths)
  # Project-local widgets
  (when (os/stat ".gent/widgets")
    (array/push discovery-paths ".gent/widgets"))
  # User-global widgets
  (def home (os/getenv "HOME"))
  (when home
    (def user-path (string home "/.gent/widgets"))
    (when (os/stat user-path)
      (array/push discovery-paths user-path))))

(defn discover-widgets
  "Discover and load widget files from discovery paths.
   Each .janet file in a widgets/ directory is loaded.
   Widget files should call (widget/register ...) to register themselves."
  []
  (init-widget-paths)
  (def loaded @[])
  (each dir discovery-paths
    (each file (os/dir dir)
      (when (string/has-suffix? ".janet" file)
        (def path (string dir "/" file))
        (try
          (do
            (dofile path)
            (array/push loaded path))
          ([err]
           (eprintf "Error loading widget %s: %s" path (string err)))))))
  loaded)
