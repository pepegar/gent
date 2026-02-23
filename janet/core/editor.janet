# Input editor — a multiline editor at the bottom of the terminal.
# Handles keypresses, cursor movement, line editing, and $EDITOR integration.
# Backed by a core/buffers buffer (*input*) for point tracking and hookability.

(import core/ui :as ui)
(import core/conversation :as conv)
(import core/buffers :as buffers)
(import core/hooks :as hooks)

(var- input-buf (buffers/create "*input*"))
(defn- get-content [] (input-buf :content))
(defn- get-cursor [] (buffers/get-point input-buf))
(defn- set-cursor [pos] (buffers/set-point input-buf pos))

(var- prompt-text "you: ")
(var- max-height 10)
(var- scroll-top 0)
(var- self-mutating false)
(var- render-suppressed false)

(defn set-prompt [p] (set prompt-text p))

(defn- get-lines []
  (string/split "\n" (string (get-content))))

(defn- line-count []
  (length (get-lines)))

(defn get-height []
  (min max-height (max 1 (line-count))))

(defn- offset->rowcol []
  (def content (get-content))
  (def cursor (get-cursor))
  (var row 0)
  (var col 0)
  (for i 0 cursor
    (if (= (content i) (chr "\n"))
      (do (++ row) (set col 0))
      (++ col)))
  [row col])

(defn- rowcol->offset [row col]
  (def lines (get-lines))
  (def clamped-row (min row (- (length lines) 1)))
  (var offset 0)
  (for r 0 clamped-row
    (+= offset (+ (length (get lines r)) 1)))
  (def line-len (length (get lines clamped-row "")))
  (def clamped-col (min col line-len))
  (+ offset clamped-col))

(defn- current-line-start []
  (def content (get-content))
  (var pos (get-cursor))
  (while (and (> pos 0) (not= (content (- pos 1)) (chr "\n")))
    (-- pos))
  pos)

(defn- current-line-end []
  (def content (get-content))
  (var pos (get-cursor))
  (while (and (< pos (length content)) (not= (content pos) (chr "\n")))
    (++ pos))
  pos)

(defn- ensure-cursor-visible []
  (def [crow _] (offset->rowcol))
  (def height (get-height))
  (when (< crow scroll-top)
    (set scroll-top crow))
  (when (>= crow (+ scroll-top height))
    (set scroll-top (- crow height -1))))

(defn- render []
  "Redraw the editor area, supporting multiple lines."
  (when render-suppressed (break))
  (def layout (ui/get-layout))
  (def input-row (layout :input-row))
  (def height (get-height))
  (def base-row (- input-row (- height 1)))
  (def [crow ccol] (offset->rowcol))
  (ensure-cursor-visible)
  (def lines (get-lines))
  (def prompt-len (+ (length prompt-text) 3))
  (def pad (string/repeat " " (- prompt-len 1)))
  (for i 0 height
    (def line-idx (+ scroll-top i))
    (def row (+ base-row i))
    (term/write (ui/move-to row 1))
    (term/write (ui/clear-line))
    (if (= i 0)
      (term/write (string (ui/color :user-label) " " prompt-text (ui/color :reset) " "))
      (term/write pad))
    (when (< line-idx (length lines))
      (term/write (get lines line-idx ""))))
  (term/write (ui/move-to (+ base-row (- crow scroll-top)) (+ prompt-len ccol))))

(defn- insert-char [ch]
  (set self-mutating true)
  (buffers/insert input-buf (get-cursor) ch)
  (set self-mutating false)
  (render))

(defn- insert-newline []
  (insert-char "\n"))

(defn- delete-back []
  (def cur (get-cursor))
  (when (> cur 0)
    (set self-mutating true)
    (buffers/delete input-buf (- cur 1) cur)
    (set self-mutating false)
    (render)))

(defn- delete-forward []
  (def cur (get-cursor))
  (def content (get-content))
  (when (< cur (length content))
    (set self-mutating true)
    (buffers/delete input-buf cur (+ cur 1))
    (set self-mutating false)
    (render)))

(defn- move-left []
  (def cur (get-cursor))
  (when (> cur 0)
    (set-cursor (- cur 1))
    (render)))

(defn- move-right []
  (def cur (get-cursor))
  (def content (get-content))
  (when (< cur (length content))
    (set-cursor (+ cur 1))
    (render)))

(defn- move-home []
  (set-cursor (current-line-start))
  (render))

(defn- move-end []
  (set-cursor (current-line-end))
  (render))

(defn- kill-line []
  "Delete from cursor to end of current line (ctrl-k). If at newline, join lines."
  (def cur (get-cursor))
  (def content (get-content))
  (def end (current-line-end))
  (set self-mutating true)
  (if (= cur end)
    (when (< cur (length content))
      (buffers/delete input-buf cur (+ cur 1)))
    (buffers/delete input-buf cur end))
  (set self-mutating false)
  (render))

(defn- kill-word-back []
  "Delete word backwards (ctrl-w)."
  (def cur (get-cursor))
  (def content (get-content))
  (when (> cur 0)
    (var pos (- cur 1))
    (while (and (> pos 0) (= (content pos) (chr " ")))
      (-- pos))
    (while (and (> pos 0) (not= (content pos) (chr " ")))
      (-- pos))
    (when (and (> pos 0) (= (content pos) (chr " ")))
      (++ pos))
    (set self-mutating true)
    (buffers/delete input-buf pos cur)
    (set self-mutating false)
    (render)))

(defn- transpose-chars []
  "Transpose the two characters before cursor (ctrl-t)."
  (def cur (get-cursor))
  (def content (get-content))
  (cond
    (and (>= (length content) 2) (= cur (length content)))
    (do
      (def a (string/from-bytes (content (- cur 2))))
      (def b (string/from-bytes (content (- cur 1))))
      (set self-mutating true)
      (buffers/delete input-buf (- cur 2) cur)
      (buffers/insert input-buf (- cur 2) (string b a))
      (set self-mutating false)
      (render))

    (and (> cur 0) (< cur (length content)))
    (do
      (def a (string/from-bytes (content (- cur 1))))
      (def b (string/from-bytes (content cur)))
      (set self-mutating true)
      (buffers/delete input-buf (- cur 1) (+ cur 1))
      (buffers/insert input-buf (- cur 1) (string b a))
      (set self-mutating false)
      (render))))

(defn- move-word-forward []
  "Move cursor forward one word (alt-f / ctrl-right)."
  (def content (get-content))
  (var pos (get-cursor))
  (while (and (< pos (length content)) (not= (content pos) (chr " ")))
    (++ pos))
  (while (and (< pos (length content)) (= (content pos) (chr " ")))
    (++ pos))
  (set-cursor pos)
  (render))

(defn- move-word-back []
  "Move cursor backward one word (alt-b / ctrl-left)."
  (def content (get-content))
  (var pos (get-cursor))
  (while (and (> pos 0) (= (content (- pos 1)) (chr " ")))
    (-- pos))
  (while (and (> pos 0) (not= (content (- pos 1)) (chr " ")))
    (-- pos))
  (set-cursor pos)
  (render))

(defn- kill-word-forward []
  "Delete from cursor to end of next word (alt-d)."
  (def content (get-content))
  (def cur (get-cursor))
  (var end cur)
  (while (and (< end (length content)) (= (content end) (chr " ")))
    (++ end))
  (while (and (< end (length content)) (not= (content end) (chr " ")))
    (++ end))
  (set self-mutating true)
  (buffers/delete input-buf cur end)
  (set self-mutating false)
  (render))

(defn- clear-input []
  "Clear the entire input (ctrl-u)."
  (def content (get-content))
  (def len (length content))
  (when (> len 0)
    (set self-mutating true)
    (buffers/delete input-buf 0 len)
    (set self-mutating false))
  (render))

(defn- open-external-editor []
  (def editor-cmd (or (os/getenv "VISUAL") (os/getenv "EDITOR") "vi"))
  (def tmpfile (string "/tmp/.gent-edit-" (math/floor (os/clock)) ".txt"))
  (spit tmpfile (string (get-content)))
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
    (def old-len (length (get-content)))
    (set self-mutating true)
    (when (> old-len 0)
      (buffers/delete input-buf 0 old-len))
    (when (> (length new-content) 0)
      (buffers/insert input-buf 0 new-content))
    (set self-mutating false)
    (set-cursor (length (get-content)))
    (os/rm tmpfile))
  (term/enable-raw-mode)
  (term/write "\x1b[?1049h")
  (term/write "\x1b[?1000h")
  (term/write "\x1b[?1006h")
  (term/write "\x1b[>1u")
  (term/write "\x1b[2J")
  (term/write "\x1b[?25h")
  (ui/restore (conv/get-messages))
  (render))

# Hook for external buffer mutations (e.g. autocomplete plugins)
(hooks/add :buffer-modified
  (fn [name _buf _kind]
    (when (and (= name "*input*") (not self-mutating))
      (render))))

(defn handle-event
  "Process a single terminal event for the editor.
   Returns:
     - a string (the submitted input) on Enter
     - [:eval string] on Alt-Enter (eval as Janet)
     - :quit on Ctrl-C/Ctrl-D
     - nil for normal keystrokes (handled, no submission)"
  [ev]
  (unless ev (break :quit))

  (when (= :key (ev :type))
    (def key (ev :key))
    (def ctrl (ev :ctrl))

    (def alt (ev :alt))

    (cond
      # Shift-Enter: insert newline
      (and (ev :shift) (= key :enter))
      (insert-newline)

      # Ctrl-G: open $EDITOR
      (and ctrl (= key "g"))
      (open-external-editor)

      # Alt-Enter: submit as Janet eval
      (and alt (= key :enter))
      (do
        (def result (string (get-content)))
        (clear-input)
        (set scroll-top 0)
        (render)
        (break [:eval result]))

      # Submit — detect comma prefix for Janet eval
      (= key :enter)
      (do
        (def result (string (get-content)))
        (clear-input)
        (set scroll-top 0)
        (render)
        (if (and (> (length result) 1) (string/has-prefix? "," result))
          (break [:eval (string/slice result 1)])
          (break result)))

      # Quit
      (and ctrl (= key "c"))
      (break :quit)

      # Ctrl-d: delete forward if buffer non-empty, quit if empty (readline behavior)
      (and ctrl (= key "d"))
      (if (> (length (get-content)) 0)
        (delete-forward)
        (break :quit))

      # Backspace
      (= key :backspace)
      (delete-back)

      # Delete
      (= key :delete)
      (delete-forward)

      # Navigation
      (= key :left)   (move-left)
      (= key :right)  (move-right)
      (= key :home)   (move-home)
      (= key :end)    (move-end)

      # Emacs-style movement
      (and ctrl (= key "a")) (move-home)
      (and ctrl (= key "e")) (move-end)
      (and ctrl (= key "b")) (move-left)
      (and ctrl (= key "f")) (move-right)

      # Emacs-style editing
      (and ctrl (= key "k")) (kill-line)
      (and ctrl (= key "u")) (clear-input)
      (and ctrl (= key "w")) (kill-word-back)
      (and ctrl (= key "h")) (delete-back)
      (and ctrl (= key "t")) (transpose-chars)

      # Alt/Meta word-level movement and editing
      (and alt (= key "f")) (move-word-forward)
      (and alt (= key "b")) (move-word-back)
      (and alt (= key "d")) (kill-word-forward)
      (and alt (= key :backspace)) (kill-word-back)

      # Scroll — page up/down and arrow up/down scroll the chat
      (= key :page-up)
      (break :scroll-up)

      (= key :page-down)
      (break :scroll-down)

      (= key :up)
      (let [[row col] (offset->rowcol)]
        (if (> row 0)
          (do (set-cursor (rowcol->offset (- row 1) col)) (render))
          (break :scroll-line-up)))

      (= key :down)
      (let [[row col] (offset->rowcol)]
        (if (< row (- (line-count) 1))
          (do (set-cursor (rowcol->offset (+ row 1) col)) (render))
          (break :scroll-line-down)))

      # Escape — clear input or signal stop
      (= key :escape)
      (if (> (length (get-content)) 0)
        (do (clear-input))
        (break :stop))

      # Suspend (ctrl-z)
      (and ctrl (= key "z"))
      (do
        (term/suspend)
        (ui/restore (conv/get-messages))
        (render))

      # Regular character
      (string? key)
      (insert-char key)))

  # Handle resize
  (when (= :resize (ev :type))
    (ui/refresh-layout)
    (ui/draw-separator)
    (render))

  nil)

(defn redraw []
  "Force a redraw of the input line. Used after spinner stops."
  (render))

(defn reset []
  "Clear the editor buffer and re-render."
  (clear-input)
  (set scroll-top 0)
  (render))

(defn batch-begin []
  "Suppress rendering until batch-end. Use when processing many events at once."
  (set render-suppressed true))

(defn batch-end []
  "End batch mode and render once."
  (set render-suppressed false)
  (render))

(defn get-input-buf []
  "Get the editor's *input* buffer for external manipulation."
  input-buf)

(defn read-input
  "Block until the user submits a line (Enter) or quits (Ctrl-C/Ctrl-D).
   Returns the input string, [:eval code-string] for Janet eval, or nil to quit."
  []
  (reset)

  (var result nil)
  (var done false)

  (while (not done)
    (def ev (term/read-event))
    (def r (handle-event ev))
    (cond
      (= r :quit) (do (set done true))
      (string? r)  (do (set result r) (set done true))
      (and (tuple? r) (= :eval (first r))) (do (set result r) (set done true))))

  result)
