# core/widget.janet — Widget protocol, registry, and layout management.
#
# The widget infrastructure for gent's TUI. Widgets are independent UI
# components with their own state, event handling, and rendering.
#
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

(defn focus
  "Set which widget receives keyboard input."
  [name]
  (when focused-name
    (when-let [w (get widgets focused-name)]
      (put w :focused false)))
  (set focused-name name)
  (when-let [w (get widgets name)]
    (put w :focused true)))

(defn focused
  "Return the currently focused widget, or nil."
  []
  (when focused-name (get widgets focused-name)))

# ── Layout ─────────────────────────────────────────────────────

(var- layout-fn nil)
(var- named-layouts @{})

(defn register-layout
  "Register a named layout function.
   Layout fn signature: (fn [area] @{:widget-name rect ...})"
  [name f]
  (put named-layouts name f))

(defn set-layout
  "Switch to a named layout."
  [name]
  (set layout-fn (get named-layouts name)))

(defn set-layout-fn
  "Set a custom layout function directly."
  [f]
  (set layout-fn f))

(defn do-layout
  "Run the layout function and assign rects to widgets.
   Returns the assignments table."
  [area]
  (when layout-fn
    (def assignments (layout-fn area))
    (eachp [name rect] assignments
      (when-let [w (get widgets name)]
        (put w :rect rect)))
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
