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
(import core/input-history :as ih)
(import core/widget :as widget)
(import tui)

(var- editor-state nil)
(var- prompt-text "")
(var- batch-mode false)
(var- char-accum @"")
(var- cached-cursor-row nil)
(var- cached-cursor-col nil)

# ── Prompt mode state ────────────────────────────────────────
# When active, the editor shows a custom prompt, optionally masks input,
# and calls a callback on Enter instead of returning the text to the reactor.
(var- prompt-mode nil)  # nil when inactive, table when active:
                        # {:label "token: " :mask true/false :callback (fn [text] ...) :saved-text ""}

# ── Prompt mode API ──────────────────────────────────────────

(defn start-prompt
  "Enter prompt mode: show a custom label, optionally mask input, call callback on Enter.
   opts: {:label string :mask bool :callback (fn [text] ...)}"
  [opts]
  (when (nil? editor-state) (break))
  (set prompt-mode
    @{:label (get opts :label "input: ")
      :mask (get opts :mask false)
      :callback (get opts :callback (fn [_] nil))
      :saved-text (ed/text editor-state)})
  (ed/set-text editor-state "")
  (widget/mark-dirty :editor))

(defn cancel-prompt
  "Cancel prompt mode without calling the callback. Restores previous editor text."
  []
  (when (nil? prompt-mode) (break))
  (def saved (prompt-mode :saved-text))
  (set prompt-mode nil)
  (when editor-state
    (ed/set-text editor-state (or saved "")))
  (widget/mark-dirty :editor))

(defn prompt-active?
  "Return true if prompt mode is active."
  []
  (not (nil? prompt-mode)))

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
    (ih/reset)
    (ed/insert-text editor-state (string char-accum))
    (buffer/clear char-accum)
    (put self :dirty true)
    # After inserting accumulated text, check for completion triggers
    (if (completion/active?)
      (update-completion-filter)
      (try-trigger-completion))))

(defn batch-begin [] (set batch-mode true))

(defn batch-end [&opt self]
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

      # ── Prompt mode key interception ──────────────────────
      # When prompt mode is active, only basic editing and Enter/Escape work.
      # No completion, no eval, no external editor.
      (when prompt-mode
        (cond
          # Enter: submit prompt input to callback
          (and (= key :enter) (not alt) (not shift))
          (do
            (def text (ed/text editor-state))
            (def callback (prompt-mode :callback))
            (def saved (prompt-mode :saved-text))
            (set prompt-mode nil)
            (ed/set-text editor-state (or saved ""))
            (put self :dirty true)
            # Call the callback — it may produce chat output
            (try (callback text) ([err] (eprintf "Prompt callback error: %s" (string err))))
            (break nil))

          # Escape: cancel prompt
          (= key :escape)
          (do
            (cancel-prompt)
            (put self :dirty true)
            (break nil))

          # Ctrl-C: cancel prompt (same as Escape here)
          (and ctrl (= key "c"))
          (do
            (cancel-prompt)
            (put self :dirty true)
            (break nil))

          # Backspace
          (= key :backspace)
          (do
            (ed/delete-back editor-state)
            (put self :dirty true)
            (break nil))

          # Left/Right movement
          (= key :left) (do (ed/move-left editor-state) (put self :dirty true) (break nil))
          (= key :right) (do (ed/move-right editor-state) (put self :dirty true) (break nil))
          (= key :home) (do (ed/move-line-start editor-state) (put self :dirty true) (break nil))
          (= key :end) (do (ed/move-line-end editor-state) (put self :dirty true) (break nil))
          (and ctrl (= key "a")) (do (ed/move-line-start editor-state) (put self :dirty true) (break nil))
          (and ctrl (= key "e")) (do (ed/move-line-end editor-state) (put self :dirty true) (break nil))

          # Ctrl-U: clear input
          (and ctrl (= key "u"))
          (do
            (ed/set-text editor-state "")
            (put self :dirty true)
            (break nil))

          # Paste / printable char
          (and (string? key) (not ctrl) (not alt))
          (do
            (ed/insert-char editor-state key)
            (put self :dirty true)
            (break nil))

          # Ignore everything else in prompt mode
          (break nil)))

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
          (ih/push text)
          (ih/reset)
          (ed/set-text editor-state "")
          (put self :dirty true)
          (if (and (> (length text) 1) (string/has-prefix? "," text))
            [:eval (string/slice text 1)]
            text))

        # Alt+Enter: eval
        (and alt (= key :enter))
        (let [text (ed/text editor-state)]
          (ih/push text)
          (ih/reset)
          (ed/set-text editor-state "")
          (put self :dirty true)
          [:eval text])

        # Escape: clear input or stop
        (= key :escape)
        (cond
          (> (length (ed/text editor-state)) 0)
          (do (ih/reset)
              (ed/set-text editor-state "")
              (put self :dirty true)
              nil)
          :stop)

        # Ctrl-Z: suspend (requires native)
        (and ctrl (= key "z"))
        (do
          (try (term/suspend) ([_] nil))
          # Re-enter alternate screen and restore TUI state after resume
          (term/write "\x1b[?1049h")  # enter alternate screen buffer
          (term/write "\x1b[2J")      # clear screen
          (term/write "\x1b[?25h")    # show cursor
          (term/write "\x1b[>1u")     # enable Kitty keyboard protocol
          (put self :dirty true)
          :rerender)

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
            # At top row — scroll chat instead of input history
            :scroll-line-up))

        (and (= key :down) (not alt) (not ctrl))
        (let [vis (ed/point->visual editor-state)
              content (ed/text editor-state)
              vlines (ed/compute-visual-lines content (editor-state :width))]
          (if (< (vis :row) (- (length vlines) 1))
            (do (ed/move-down editor-state)
                (put self :dirty true)
                nil)
            # At bottom row — scroll chat instead of input history
            :scroll-line-down))

        # Ctrl+Up: Previous input history
        (and ctrl (= key :up))
        (let [entry (ih/prev (ed/text editor-state))]
          (if entry
            (do (ed/set-text editor-state entry)
                (put self :dirty true)
                nil)
            nil))

        # Ctrl+Down: Next input history (when browsing)
        (and ctrl (= key :down))
        (if (ih/browsing?)
          (let [entry (ih/next)]
            (if entry
              (do (ed/set-text editor-state entry)
                  (put self :dirty true)
                  nil)
              nil))
          nil)

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
            (term/write "\x1b[?1002l")
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
            (term/write "\x1b[?1002h")
            (term/write "\x1b[?1006h")
            (term/write "\x1b[>1u")
            (term/write "\x1b[2J")
            (term/write "\x1b[?25h"))
          (put self :dirty true)
          :rerender)

        # Ctrl+T: toggle thinking visibility
        (and ctrl (= key "t"))
        :toggle-thinking

        # All other keys → editor_new, then check trigger
        (do
          # Reset history browsing on any text-modifying key
          (when (and (ih/browsing?)
                     (or (string? key)
                         (= key :backspace)
                         (= key :delete)
                         (and ctrl (or (= key "k") (= key "u") (= key "w") (= key "d")
                                       (= key "h")))
                         (and alt (or (= key "d") (= key :backspace)))))
            (ih/reset))
          (ed/handle-key editor-state event)
          (put self :dirty true)
          # After any printable char, check for completion triggers
          (when (and (string? key) (not ctrl) (not alt) (not (completion/active?)))
            (try-trigger-completion))
          nil)))

    :render (fn [self rect buf]
      (when (nil? rect) (break))
      (put editor-state :widget-rect rect)

      # Determine prompt label based on mode
      (def current-prompt (if prompt-mode (prompt-mode :label) prompt-text))
      (def is-masked (and prompt-mode (prompt-mode :mask)))

      # Resize editor to match widget rect
      (def has-prompt (> (length current-prompt) 0))
      (def prompt-len (if has-prompt (+ (length current-prompt) 2) 1))
      (def edit-width (max 1 (- (rect :width) prompt-len)))
      (ed/resize editor-state edit-width (rect :height))

      (def r (ed/render editor-state))
      (def lines (r :lines))
      (def vis-cursor (r :cursor))
      (def spans (or (r :spans) @[]))
      (set cached-cursor-row (+ (rect :y) (vis-cursor :row) 1))
      (set cached-cursor-col (+ (rect :x) prompt-len (vis-cursor :col) 1))
      (def prompt-style
        (if prompt-mode
          (tui/style :fg (tui/color-indexed 214) :bold true)
          (tui/style :fg (tui/color-indexed 39) :bold true)))
      (def pad (string/repeat " " prompt-len))

      (for i 0 (rect :height)
        (def y (+ (rect :y) i))
        (if (= i 0)
          (do
            (tui/buffer-set-string buf (rect :x) y
              (if has-prompt
                (string " " current-prompt " ")
                " ")
              prompt-style)
            (when (< i (length lines))
              (def line-text (get lines i ""))
              (def display-text
                (if is-masked
                  (string/repeat "•" (length line-text))
                  line-text))
              (tui/buffer-set-string buf (+ (rect :x) prompt-len) y display-text)))
          (do
            (tui/buffer-set-string buf (rect :x) y pad)
            (when (< i (length lines))
              (def line-text (get lines i ""))
              (def display-text
                (if is-masked
                  (string/repeat "•" (length line-text))
                  line-text))
              (tui/buffer-set-string buf (+ (rect :x) prompt-len) y display-text)))))

      # Apply styled spans (skip in masked mode)
      (unless is-masked
        (each span spans
          (def y (+ (rect :y) (span :row)))
          (for col (span :col-start) (span :col-end)
            (def x (+ (rect :x) prompt-len col))
            (def cell (tui/buffer-get buf x y))
            (tui/buffer-set-char buf x y (cell :ch)
              (tui/style-merge (cell :style) (span :style)))))))})