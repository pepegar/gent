# Input editor — a single-line editor fixed at the bottom of the terminal.
# Handles keypresses, cursor movement, and basic line editing.

(import core/ui :as ui)
(import core/conversation :as conv)

(var- buf @"")
(var- cursor 0)
(var- prompt-text "you: ")

(defn set-prompt [p] (set prompt-text p))

(defn- render []
  "Redraw the input line at the editor row."
  (def layout (ui/get-layout))
  (term/write (ui/move-to (layout :input-row) 1))
  (term/write (ui/clear-line))
  (term/write (string (ui/color :user-label) " " prompt-text (ui/color :reset) " "))
  (term/write (string buf))
  # Position cursor correctly (prompt + space + cursor offset)
  (def prompt-len (+ (length prompt-text) 3))
  (term/write (ui/move-to (layout :input-row) (+ prompt-len cursor))))

(defn- insert-char [ch]
  (if (= cursor (length buf))
    (buffer/push buf ch)
    (do
      (def after (buffer/slice buf cursor))
      (buffer/popn buf (- (length buf) cursor))
      (buffer/push buf ch)
      (buffer/push buf after)))
  (++ cursor)
  (render))

(defn- delete-back []
  (when (> cursor 0)
    (def before (buffer/slice buf 0 (- cursor 1)))
    (def after (buffer/slice buf cursor))
    (buffer/clear buf)
    (buffer/push buf before)
    (buffer/push buf after)
    (-- cursor)
    (render)))

(defn- delete-forward []
  (when (< cursor (length buf))
    (def before (buffer/slice buf 0 cursor))
    (def after (buffer/slice buf (+ cursor 1)))
    (buffer/clear buf)
    (buffer/push buf before)
    (buffer/push buf after)
    (render)))

(defn- move-left []
  (when (> cursor 0)
    (-- cursor)
    (render)))

(defn- move-right []
  (when (< cursor (length buf))
    (++ cursor)
    (render)))

(defn- move-home []
  (set cursor 0)
  (render))

(defn- move-end []
  (set cursor (length buf))
  (render))

(defn- kill-line []
  "Delete from cursor to end of line (ctrl-k)."
  (buffer/popn buf (- (length buf) cursor))
  (render))

(defn- kill-word-back []
  "Delete word backwards (ctrl-w)."
  (when (> cursor 0)
    # Skip trailing spaces
    (var pos (- cursor 1))
    (while (and (> pos 0) (= (buf pos) (chr " ")))
      (-- pos))
    # Skip word characters
    (while (and (> pos 0) (not= (buf pos) (chr " ")))
      (-- pos))
    (when (and (> pos 0) (= (buf pos) (chr " ")))
      (++ pos))
    (def before (buffer/slice buf 0 pos))
    (def after (buffer/slice buf cursor))
    (buffer/clear buf)
    (buffer/push buf before)
    (buffer/push buf after)
    (set cursor pos)
    (render)))

(defn- transpose-chars []
  "Transpose the two characters before cursor (ctrl-t)."
  (cond
    # At least 2 chars and cursor at end — swap last two
    (and (>= (length buf) 2) (= cursor (length buf)))
    (do
      (def tmp (buf (- cursor 1)))
      (put buf (- cursor 1) (buf (- cursor 2)))
      (put buf (- cursor 2) tmp)
      (render))
    # In the middle — swap char under cursor with previous
    (and (> cursor 0) (< cursor (length buf)))
    (do
      (def tmp (buf cursor))
      (put buf cursor (buf (- cursor 1)))
      (put buf (- cursor 1) tmp)
      (++ cursor)
      (render))))

(defn- move-word-forward []
  "Move cursor forward one word (alt-f / ctrl-right)."
  # Skip non-space characters first (current word)
  (while (and (< cursor (length buf)) (not= (buf cursor) (chr " ")))
    (++ cursor))
  # Skip spaces
  (while (and (< cursor (length buf)) (= (buf cursor) (chr " ")))
    (++ cursor))
  (render))

(defn- move-word-back []
  "Move cursor backward one word (alt-b / ctrl-left)."
  # Skip spaces before cursor
  (while (and (> cursor 0) (= (buf (- cursor 1)) (chr " ")))
    (-- cursor))
  # Skip word characters
  (while (and (> cursor 0) (not= (buf (- cursor 1)) (chr " ")))
    (-- cursor))
  (render))

(defn- kill-word-forward []
  "Delete from cursor to end of next word (alt-d)."
  (var end cursor)
  # Skip spaces
  (while (and (< end (length buf)) (= (buf end) (chr " ")))
    (++ end))
  # Skip word characters
  (while (and (< end (length buf)) (not= (buf end) (chr " ")))
    (++ end))
  (def before (buffer/slice buf 0 cursor))
  (def after (buffer/slice buf end))
  (buffer/clear buf)
  (buffer/push buf before)
  (buffer/push buf after)
  (render))

(defn- clear-input []
  "Clear the entire input (ctrl-u)."
  (buffer/clear buf)
  (set cursor 0)
  (render))

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
      # Alt-Enter: submit as Janet eval
      (and alt (= key :enter))
      (do
        (def result (string buf))
        (buffer/clear buf)
        (set cursor 0)
        (render)
        (break [:eval result]))

      # Submit — detect comma prefix for Janet eval
      (= key :enter)
      (do
        (def result (string buf))
        (buffer/clear buf)
        (set cursor 0)
        (render)
        # If input starts with "," treat as Janet eval (strip the comma)
        (if (and (> (length result) 1) (string/has-prefix? "," result))
          (break [:eval (string/slice result 1)])
          (break result)))

      # Quit
      (and ctrl (= key "c"))
      (break :quit)

      # Ctrl-d: delete forward if buffer non-empty, quit if empty (readline behavior)
      (and ctrl (= key "d"))
      (if (> (length buf) 0)
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

      # Escape — clear input or signal stop
      (= key :escape)
      (if (> (length buf) 0)
        (do (clear-input))
        (break :stop))

      # Suspend (ctrl-z)
      (and ctrl (= key "z"))
      (do
        (term/suspend)
        # Restore TUI after resume — replay conversation history
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
  (buffer/clear buf)
  (set cursor 0)
  (render))

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
