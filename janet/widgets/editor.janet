# widgets/editor.janet — Input editor widget.
#
# Wraps widgets/editor_new (the pure editing logic) and bridges it
# to the widget system. Returns signals the reactor understands:
# :quit, :stop, string (submitted text), [:eval code].
#
# Integrates with core/completion for autocompletion popup:
# Tab/Up/Down/Escape intercepted when popup active.

(import core/buffers :as buffers)
(import widgets/editor_new :as ed)
(import core/completion :as completion)
(import tui)

(var- editor-state nil)
(var- prompt-text "you: ")
(var- batch-mode false)
(var- char-accum @"")
(var- cached-cursor-row nil)
(var- cached-cursor-col nil)

# ── Public API for the reactor ───────────────────────────────

(defn get-height
  "How many rows the editor needs."
  []
  (if (nil? editor-state) 5
    (or (editor-state :height) 5)))

(defn get-editor-state [] editor-state)

(defn get-cursor-screen-pos
  "Return [row col] of cursor in 1-indexed screen coordinates."
  []
  [cached-cursor-row cached-cursor-col])

(defn redraw
  "Position the terminal cursor based on cached render result."
  []
  (when (and cached-cursor-row cached-cursor-col)
    (term/write (string "\x1b[" cached-cursor-row ";" cached-cursor-col "H"))))

# ── Completion helpers ───────────────────────────────────────
# Defined before flush-accum because flush-accum calls them.

(defn- try-trigger-completion []
  "Check if the last typed character should activate completion."
  (def content (ed/text editor-state))
  (def pt (ed/point editor-state))
  (def trigger (completion/check-trigger content pt))
  (when trigger
    (completion/activate (trigger :kind) (trigger :start))
    (completion/filter-candidates content pt)))

(defn- update-completion-filter []
  "Re-filter candidates after a text change. Dismiss if no matches or prefix gone."
  (def content (ed/text editor-state))
  (def pt (ed/point editor-state))
  (when (< pt (completion/get-trigger-start))
    (completion/dismiss)
    (break))
  (def count (completion/filter-candidates content pt))
  (when (= count 0)
    (completion/dismiss)))

(defn- accept-completion [self]
  "Accept the selected completion candidate."
  (def content (ed/text editor-state))
  (def pt (ed/point editor-state))
  (def result (completion/accept pt))
  (when result
    (def start (result :start))
    (def end (result :end))
    (def insert-text (result :insert))

    # Delete from trigger-start to current point, then insert
    (def buf (editor-state :buf))
    (when (> end start)
      (buffers/delete buf start end))
    (buffers/insert buf start insert-text)
    (buffers/set-point buf (+ start (length insert-text)))

    # Add styled span for the inserted completion
    (ed/add-styled-span editor-state start (+ start (length insert-text))
      (completion/get-style))

    (put self :dirty true)))

# ── Batch mode ───────────────────────────────────────────────

(defn- flush-accum [self]
  (when (> (length char-accum) 0)
    (ed/insert-text editor-state (string char-accum))
    (buffer/clear char-accum)
    (put self :dirty true)
    # After inserting accumulated text, check for completion triggers
    (if (completion/active?)
      (update-completion-filter)
      (try-trigger-completion))))

(defn batch-begin [] (set batch-mode true))

(defn batch-end [&opt self]
  (import core/widget :as widget)
  (def w (or self (widget/get-widget :editor)))
  (when w (flush-accum w))
  (set batch-mode false))

# ── Widget ───────────────────────────────────────────────────

(defn create
  "Create an editor widget backed by editor_new."
  []
  (set editor-state (ed/new 80 5))
  @{:name :editor
    :state @{}
    :rect nil
    :dirty true
    :focused true
    :tasks @[]
    :timers @[]

    :handle (fn [self event]
      (when (= :resize (get event :type))
        (break nil))
      (when (not= :key (get event :type))
        (break nil))

      (def key (get event :key))
      (def ctrl (get event :ctrl false))
      (def alt (get event :alt false))
      (def shift (get event :shift false))

      # ── Completion-active key interception ────────────────
      (when (completion/active?)
        (cond
          # Tab: accept selected candidate
          (= key :tab)
          (do
            (accept-completion self)
            (put self :dirty true)
            (break nil))

          # Up: select previous
          (and (= key :up) (not alt) (not ctrl))
          (do
            (completion/select-prev)
            (put self :dirty true)
            (break nil))

          # Down: select next
          (and (= key :down) (not alt) (not ctrl))
          (do
            (completion/select-next)
            (put self :dirty true)
            (break nil))

          # Escape: dismiss popup (don't clear editor)
          (= key :escape)
          (do
            (completion/dismiss)
            (put self :dirty true)
            (break nil))

          # Enter: accept selected candidate (same as Tab)
          (and (= key :enter) (not alt) (not shift))
          (do
            (accept-completion self)
            (put self :dirty true)
            (break nil))

          # Backspace: pass to editor, re-filter
          (= key :backspace)
          (do
            (ed/delete-back editor-state)
            (update-completion-filter)
            (put self :dirty true)
            (break nil))

          # Printable char: pass to editor, re-filter
          (and (string? key) (not ctrl) (not alt))
          (do
            (ed/insert-char editor-state key)
            (update-completion-filter)
            (put self :dirty true)
            (break nil))))

      # ── Normal key handling (completion idle or non-intercepted) ──

      # In batch mode, accumulate plain printable chars
      (when (and batch-mode (string? key) (not ctrl) (not alt))
        (buffer/push char-accum key)
        (break nil))

      # Any non-printable key flushes the accumulator first
      (flush-accum self)

      (cond
        # Ctrl-C: quit
        (and ctrl (= key "c"))
        :quit

        # Ctrl-D: delete forward if non-empty, quit if empty
        (and ctrl (= key "d"))
        (if (> (length (ed/text editor-state)) 0)
          (do (ed/delete-forward editor-state)
              (put self :dirty true)
              nil)
          :quit)

        # Enter (no modifiers): submit
        (and (= key :enter) (not alt) (not shift))
        (let [text (ed/text editor-state)]
          (ed/set-text editor-state "")
          (put self :dirty true)
          (if (and (> (length text) 1) (string/has-prefix? "," text))
            [:eval (string/slice text 1)]
            text))

        # Alt+Enter: eval
        (and alt (= key :enter))
        (let [text (ed/text editor-state)]
          (ed/set-text editor-state "")
          (put self :dirty true)
          [:eval text])

        # Escape: clear or stop
        (= key :escape)
        (if (> (length (ed/text editor-state)) 0)
          (do (ed/set-text editor-state "")
              (put self :dirty true)
              nil)
          :stop)

        # Ctrl-Z: suspend (requires native)
        (and ctrl (= key "z"))
        (do
          (try (term/suspend) ([_] nil))
          (put self :dirty true)
          nil)

        # Page up/down, arrow up/down at boundary → scroll signals
        (= key :page-up)
        :scroll-up

        (= key :page-down)
        :scroll-down

        (and (= key :up) (not alt) (not ctrl))
        (let [vis (ed/point->visual editor-state)]
          (if (> (vis :row) 0)
            (do (ed/move-up editor-state)
                (put self :dirty true)
                nil)
            :scroll-line-up))

        (and (= key :down) (not alt) (not ctrl))
        (let [vis (ed/point->visual editor-state)
              content (ed/text editor-state)
              vlines (ed/compute-visual-lines content (editor-state :width))]
          (if (< (vis :row) (- (length vlines) 1))
            (do (ed/move-down editor-state)
                (put self :dirty true)
                nil)
            :scroll-line-down))

        # Ctrl+G: open external editor
        (and ctrl (= key "g"))
        (do
          (def result (ed/open-external editor-state))
          (when (= (result :action) :open-external)
            (def editor-cmd (or (os/getenv "VISUAL") (os/getenv "EDITOR") "vi"))
            (def tmpfile (string "/tmp/.gent-edit-" (math/floor (os/clock)) ".txt"))
            (spit tmpfile (result :text))
            (term/write "\x1b[<u")
            (term/write "\x1b[?1006l")
            (term/write "\x1b[?1000l")
            (term/write "\x1b[?25h")
            (term/write "\x1b[?1049l")
            (term/disable-raw-mode)
            (try
              (do
                (def proc (os/spawn [editor-cmd tmpfile] :p))
                (os/proc-wait proc))
              ([err] (eprint "Editor failed: " err)))
            (when (os/stat tmpfile)
              (def new-content (string/trimr (slurp tmpfile)))
              (ed/set-text editor-state new-content)
              (os/rm tmpfile))
            (term/enable-raw-mode)
            (term/write "\x1b[?1049h")
            (term/write "\x1b[?1000h")
            (term/write "\x1b[?1006h")
            (term/write "\x1b[>1u")
            (term/write "\x1b[2J")
            (term/write "\x1b[?25h"))
          (put self :dirty true)
          :rerender)

        # All other keys → editor_new, then check trigger
        (do
          (ed/handle-key editor-state event)
          (put self :dirty true)
          # After any printable char, check for completion triggers
          (when (and (string? key) (not ctrl) (not alt) (not (completion/active?)))
            (try-trigger-completion))
          nil)))

    :render (fn [self rect buf]
      (when (nil? rect) (break))
      (put editor-state :widget-rect rect)

      # Resize editor to match widget rect
      (def prompt-len (+ (length prompt-text) 3))
      (def edit-width (max 1 (- (rect :width) prompt-len)))
      (ed/resize editor-state edit-width (rect :height))

      (def r (ed/render editor-state))
      (def lines (r :lines))
      (def vis-cursor (r :cursor))
      (def spans (or (r :spans) @[]))
      (set cached-cursor-row (+ (rect :y) (vis-cursor :row) 1))
      (set cached-cursor-col (+ (rect :x) prompt-len (vis-cursor :col) 1))
      (def prompt-style (tui/style :fg (tui/color-indexed 39) :bold true))
      (def pad (string/repeat " " (- prompt-len 1)))

      (for i 0 (rect :height)
        (def y (+ (rect :y) i))
        (if (= i 0)
          (do
            (tui/buffer-set-string buf (rect :x) y
              (string " " prompt-text " ") prompt-style)
            (when (< i (length lines))
              (tui/buffer-set-string buf (+ (rect :x) prompt-len) y
                (get lines i ""))))
          (do
            (tui/buffer-set-string buf (rect :x) y pad)
            (when (< i (length lines))
              (tui/buffer-set-string buf (+ (rect :x) prompt-len) y
                (get lines i ""))))))

      # Apply styled spans
      (each span spans
        (def y (+ (rect :y) (span :row)))
        (for col (span :col-start) (span :col-end)
          (def x (+ (rect :x) prompt-len col))
          (def cell (tui/buffer-get buf x y))
          (tui/buffer-set-char buf x y (cell :ch)
            (tui/style-merge (cell :style) (span :style))))))})
