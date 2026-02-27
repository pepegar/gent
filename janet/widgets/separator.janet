# widgets/separator.janet — Status bar separator widget.
#
# A single-row widget displaying a separator line with status info.
# Renders into the shared screen buffer (Phase 3 full-buffer rendering).

(import tui)

# ── Status provider ────────────────────────────────────────────

(var- status-fn nil)

(defn set-status-provider
  "Set a function that returns status text for the separator."
  [f]
  (set status-fn f))

# ── Widget ─────────────────────────────────────────────────────

(defn create
  "Create a separator widget."
  []
  @{:name :separator
    :state @{}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[]

    :handle (fn [self event] nil)

    :render (fn [self rect buf]
             (when (or (nil? rect) (<= (rect :width) 0)) (break))
             (def cols (rect :width))
             (def sep-style (tui/style :fg (tui/color-indexed 240)))

             (def status (when status-fn (try (status-fn) ([_] nil))))
             (if status
               (do
                 (def status-text (string " " status " "))
                 (var char-count 0)
                 (var i 0)
                 (while (< i (length status-text))
                   (def byte (get status-text i))
                   (def char-len (cond (< byte 0x80) 1 (< byte 0xE0) 2 (< byte 0xF0) 3 4))
                   (set i (+ i char-len))
                   (++ char-count))
                 (def left-dashes 2)
                 (def right-dashes (max 0 (- cols left-dashes char-count)))
                 (var col (rect :x))
                 (for _ 0 left-dashes
                   (tui/buffer-set-char buf col (rect :y) "─" sep-style)
                   (++ col))
                 (tui/buffer-set-string buf col (rect :y) status-text sep-style)
                 (set col (+ col char-count))
                 (for _ 0 right-dashes
                   (when (< col (+ (rect :x) cols))
                     (tui/buffer-set-char buf col (rect :y) "─" sep-style)
                     (++ col))))
               (do
                 (for col 0 cols
                   (tui/buffer-set-char buf (+ (rect :x) col) (rect :y) "─" sep-style)))))})
