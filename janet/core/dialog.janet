# core/dialog.janet — Interactive dialog state machine and overlay renderer.
#
# Provides a modal dialog overlay for mid-conversation questions.
# Three dialog types: :select (pick from options), :confirm (yes/no),
# :input (free-form text).
#
# State machine: :idle → show() → :active → submit()/dismiss() → :idle

(import core/widget :as widget)
(import tui)

# ── State ────────────────────────────────────────────────────

(var- state :idle)
(var- dialog-type nil)
(var- title "")
(var- options @[])
(var- selected 0)
(var- scroll-offset 0)
(var- input-text "")
(var- input-cursor 0)
(var- result-box nil)

# ── Constants ────────────────────────────────────────────────

(def- max-dialog-width 60)
(def- max-visible-options 10)

# ── Public API ───────────────────────────────────────────────

(defn active? [] (= state :active))

(defn get-type [] dialog-type)

(defn get-input-text [] input-text)

(defn reset-state
  "Reset all state to idle. Useful for tests."
  []
  (set state :idle)
  (set dialog-type nil)
  (set title "")
  (set options @[])
  (set selected 0)
  (set scroll-offset 0)
  (set input-text "")
  (set input-cursor 0)
  (set result-box nil))

(defn show
  "Open a dialog. Returns a mutable result-box that gets filled on submit/dismiss.
   opts: {:type :select|:confirm|:input :title string
          :options [{:label :value}] :default string}"
  [opts]
  (set dialog-type (get opts :type :select))
  (set title (get opts :title ""))
  (set options
    (case dialog-type
      :confirm @[@{:label "Yes" :value "yes"} @{:label "No" :value "no"}]
      :input @[]
      (let [raw (get opts :options @[])
            normalized @[]]
        (each o raw
          (if (string? o)
            (array/push normalized @{:label o :value o})
            (array/push normalized @{:label (get o :label "")
                                     :value (get o :value (get o :label ""))})))
        normalized)))
  (set selected 0)
  (set scroll-offset 0)
  (set input-text (or (get opts :default) ""))
  (set input-cursor (length input-text))
  (set state :active)
  (set result-box @{:value nil :cancelled false})
  (widget/mark-dirty :chat)
  result-box)

(defn dismiss
  "Close the dialog without a result (user cancelled)."
  []
  (when (= state :idle) (break))
  (set state :idle)
  (when result-box
    (put result-box :cancelled true))
  (widget/mark-dirty :chat))

(defn submit
  "Close the dialog with the current selection/input."
  []
  (when (= state :idle) (break))
  (def value
    (case dialog-type
      :input input-text
      (if (and (>= selected 0) (< selected (length options)))
        (get-in options [selected :value])
        nil)))
  (set state :idle)
  (when result-box
    (put result-box :value value))
  (widget/mark-dirty :chat))

(defn select-next
  "Highlight the next option (wraps around)."
  []
  (when (empty? options) (break))
  (if (< selected (- (length options) 1))
    (set selected (+ selected 1))
    (set selected 0))
  (when (>= selected (+ scroll-offset max-visible-options))
    (set scroll-offset (- selected max-visible-options -1)))
  (when (< selected scroll-offset)
    (set scroll-offset selected))
  (widget/mark-dirty :chat))

(defn select-prev
  "Highlight the previous option (wraps around)."
  []
  (when (empty? options) (break))
  (if (> selected 0)
    (set selected (- selected 1))
    (set selected (- (length options) 1)))
  (when (< selected scroll-offset)
    (set scroll-offset selected))
  (when (>= selected (+ scroll-offset max-visible-options))
    (set scroll-offset (- selected max-visible-options -1)))
  (widget/mark-dirty :chat))

(defn select-idx
  "Jump to an option by index (0-based) and submit."
  [idx]
  (when (and (>= idx 0) (< idx (length options)))
    (set selected idx)
    (submit)))

(defn input-insert
  "Insert a character at the cursor position."
  [ch]
  (when (not= dialog-type :input) (break))
  (set input-text
    (string (string/slice input-text 0 input-cursor) ch (string/slice input-text input-cursor)))
  (+= input-cursor (length ch))
  (widget/mark-dirty :chat))

(defn input-delete-back
  "Delete the character before the cursor."
  []
  (when (not= dialog-type :input) (break))
  (when (> input-cursor 0)
    (-- input-cursor)
    (set input-text
      (string (string/slice input-text 0 input-cursor)
              (string/slice input-text (+ input-cursor 1))))
    (widget/mark-dirty :chat)))

(defn input-move-left
  "Move cursor left."
  []
  (when (> input-cursor 0) (-- input-cursor)))

(defn input-move-right
  "Move cursor right."
  []
  (when (< input-cursor (length input-text)) (++ input-cursor)))

(defn input-clear
  "Clear the input text."
  []
  (set input-text "")
  (set input-cursor 0)
  (widget/mark-dirty :chat))

# ── Overlay rendering helpers ────────────────────────────────

(defn- emit-content-row
  "Emit a content row with border chars on left and right."
  [cells popup-x popup-width inner-width border-style y text style]
  (array/push cells {:x popup-x :y y :ch "│" :style border-style})
  # Walk text by UTF-8 codepoints (not raw bytes)
  (var col 0)
  (var i 0)
  (def len (length text))
  (while (and (< col inner-width) (< i len))
    (def byte (get text i))
    (def char-len
      (cond
        (< byte 0x80) 1
        (< byte 0xE0) 2
        (< byte 0xF0) 3
        4))
    (def ch (string/slice text i (min (+ i char-len) len)))
    (array/push cells {:x (+ popup-x 1 col) :y y :ch ch :style style})
    (+= i char-len)
    (++ col))
  # Fill remaining columns with spaces
  (while (< col inner-width)
    (array/push cells {:x (+ popup-x 1 col) :y y :ch " " :style style})
    (++ col))
  (array/push cells {:x (+ popup-x popup-width -1) :y y :ch "│" :style border-style}))

# ── Overlay rendering ────────────────────────────────────────

(defn render-overlay
  "Compute dialog overlay as cell array for compositing.
   screen-area: tui rect of the full screen.
   Returns {:cells [{:x :y :ch :style}] :width :height :x :y} or nil."
  [screen-area]
  (when (not= state :active) (break nil))

  (def border-style (tui/style :fg :cyan))
  (def title-style (tui/style :fg :cyan :bold true))
  (def normal-style (tui/style))
  (def selected-style (tui/style :reversed true))
  (def hint-style (tui/style :fg :bright-black))

  (def popup-width (min max-dialog-width (- (screen-area :width) 4)))
  (def inner-width (- popup-width 2))
  (when (<= inner-width 0) (break nil))

  (def content-rows
    (case dialog-type
      :input 1
      (min (length options) max-visible-options)))

  # top-border + padding + content + padding + hint + bottom-border
  (def popup-height (+ content-rows 5))

  (def popup-x (math/floor (/ (- (screen-area :width) popup-width) 2)))
  (def popup-y (math/floor (/ (- (screen-area :height) popup-height) 2)))
  (when (or (< popup-x 0) (< popup-y 0)) (break nil))

  (def cells @[])

  # ── Top border with title ──
  (array/push cells {:x popup-x :y popup-y :ch "╭" :style border-style})
  (array/push cells {:x (+ popup-x 1) :y popup-y :ch "─" :style border-style})
  (def title-display (string " " title " "))
  # Walk title by UTF-8 codepoints
  (var tcol 0)
  (var ti 0)
  (def tlen (length title-display))
  (def max-title-cols (- inner-width 1))
  (while (and (< tcol max-title-cols) (< ti tlen))
    (def byte (get title-display ti))
    (def char-len
      (cond
        (< byte 0x80) 1
        (< byte 0xE0) 2
        (< byte 0xF0) 3
        4))
    (def ch (string/slice title-display ti (min (+ ti char-len) tlen)))
    (array/push cells {:x (+ popup-x 2 tcol) :y popup-y
                        :ch ch :style title-style})
    (+= ti char-len)
    (++ tcol))
  (for col (+ 2 tcol) (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y popup-y :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y popup-y :ch "╮" :style border-style})

  # ── Padding row ──
  (emit-content-row cells popup-x popup-width inner-width border-style
    (+ popup-y 1) "" normal-style)

  # ── Content rows ──
  (case dialog-type
    :input
    (do
      (def display (string "  > " input-text))
      (emit-content-row cells popup-x popup-width inner-width border-style
        (+ popup-y 2) display normal-style))

    (do
      (def start-idx scroll-offset)
      (def end-idx (min (+ start-idx content-rows) (length options)))
      (for i start-idx end-idx
        (def row (- i start-idx))
        (def opt (get options i))
        (def is-sel (= i selected))
        (def indicator (if is-sel ">" " "))
        (def text (string/format " %s %d. %s" indicator (+ i 1) (opt :label)))
        (def trimmed (if (> (length text) inner-width)
                       (string/slice text 0 inner-width)
                       text))
        (emit-content-row cells popup-x popup-width inner-width border-style
          (+ popup-y 2 row) trimmed
          (if is-sel selected-style normal-style)))))

  # ── Padding row ──
  (emit-content-row cells popup-x popup-width inner-width border-style
    (+ popup-y 2 content-rows) "" normal-style)

  # ── Hint row ──
  (def hint
    (case dialog-type
      :input "  enter submit  esc cancel"
      "  ↑↓/jk navigate  1-9 jump  enter select  esc cancel"))
  (def trimmed-hint (if (> (length hint) inner-width)
                      (string/slice hint 0 inner-width)
                      hint))
  (emit-content-row cells popup-x popup-width inner-width border-style
    (+ popup-y 3 content-rows) trimmed-hint hint-style)

  # ── Bottom border ──
  (def bottom-y (+ popup-y 4 content-rows))
  (array/push cells {:x popup-x :y bottom-y :ch "╰" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y bottom-y :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y bottom-y :ch "╯" :style border-style})

  {:cells cells
   :width popup-width
   :height popup-height
   :x popup-x
   :y popup-y})
