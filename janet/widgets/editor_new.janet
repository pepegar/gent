# widgets/editor_new.janet — Rich multiline input editor.
#
# View layer on top of core/buffers. Provides word wrapping,
# emacs-style keybindings, undo/redo, kill ring, and scrolling.
# Does not own the text — wraps a gent buffer.

(import core/buffers :as buffers)

(var- next-id 0)

# ── Coordinate Helpers ───────────────────────────────────────

(defn point->line-col
  "Convert byte offset to {:line :col}."
  [content point]
  (def p (min point (length content)))
  (var line 0)
  (var col 0)
  (for i 0 p
    (if (= (get content i) (chr "\n"))
      (do (++ line) (set col 0))
      (++ col)))
  {:line line :col col})

(defn line-start-offset
  "Byte offset of the start of logical line N."
  [content line-num]
  (if (= line-num 0)
    0
    (do
      (var line 0)
      (var i 0)
      (while (< i (length content))
        (when (= (get content i) (chr "\n"))
          (++ line)
          (when (= line line-num)
            (break)))
        (++ i))
      (if (= line line-num)
        (+ i 1)
        (length content)))))

(defn line-end-offset
  "Byte offset of the end of logical line N (before its newline)."
  [content line-num]
  (def start (line-start-offset content line-num))
  (var i start)
  (while (and (< i (length content)) (not= (get content i) (chr "\n")))
    (++ i))
  i)

(defn line-col->point
  "Convert {:line :col} to byte offset."
  [content line col]
  (def start (line-start-offset content line))
  (def end (line-end-offset content line))
  (def line-len (- end start))
  (+ start (min col line-len)))

# ── Word Wrapping ────────────────────────────────────────────

(defn wrap-line
  "Wrap a single logical line at word boundaries. Returns array of
   {:text :start :end} segments with offsets relative to the line."
  [line width]
  (when (= width 0) (break @[{:text "" :start 0 :end 0}]))
  (when (= (length line) 0)
    (break @[{:text "" :start 0 :end 0}]))

  (def segments @[])
  (var seg-start 0)
  (var col 0)
  (var last-space nil)
  (var i 0)

  (while (< i (length line))
    (def ch (get line i))
    (when (= ch (chr " "))
      (set last-space i))

    (if (>= col width)
      (do
        (if (and last-space (> last-space seg-start))
          (do
            (def break-at (+ last-space 1))
            (array/push segments
              {:text (string/slice line seg-start break-at)
               :start seg-start
               :end break-at})
            (set seg-start break-at)
            (set col (- i break-at))
            (set last-space nil))
          (do
            (array/push segments
              {:text (string/slice line seg-start i)
               :start seg-start
               :end i})
            (set seg-start i)
            (set col 0)
            (set last-space nil)))
        (++ col)
        (++ i))
      (do
        (++ col)
        (++ i))))

  (when (<= seg-start (length line))
    (array/push segments
      {:text (string/slice line seg-start)
       :start seg-start
       :end (length line)}))

  (if (empty? segments)
    @[{:text "" :start 0 :end 0}]
    segments))

(defn compute-visual-lines
  "Split content into logical lines, wrap each, return flat array of
   visual line segments with absolute byte offsets into the content buffer."
  [content width]
  (def lines (string/split "\n" (string content)))
  (def result @[])
  (var abs-offset 0)

  (each line lines
    (def segs (wrap-line line width))
    (each seg segs
      (array/push result
        {:text (seg :text)
         :start (+ abs-offset (seg :start))
         :end (+ abs-offset (seg :end))
         :logical-start abs-offset}))
    (+= abs-offset (+ (length line) 1)))

  result)

(defn point->visual
  "Map buffer point to {:row :col} in visual line coordinates."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def point (buffers/get-point buf))
  (def width (state :width))
  (def vlines (compute-visual-lines content width))

  (when (empty? vlines)
    (break {:row 0 :col 0}))

  (var row 0)
  (var col 0)
  (for i 0 (length vlines)
    (def vl (get vlines i))
    (def seg-start (vl :start))
    (def seg-end (vl :end))
    (if (and (>= point seg-start)
             (or (< point seg-end)
                 (and (= point seg-end)
                      (= i (- (length vlines) 1)))
                 (and (= point seg-end)
                      (< i (- (length vlines) 1))
                      (= point (get-in vlines [(+ i 1) :start])))))
      (do
        (set row i)
        (set col (- point seg-start))
        (when (or (< point seg-end)
                  (= i (- (length vlines) 1)))
          (break)))
      (when (and (= point seg-end)
                 (< i (- (length vlines) 1))
                 (not= point (get-in vlines [(+ i 1) :start])))
        (set row i)
        (set col (- point seg-start))
        (break))))

  {:row row :col col})

(defn visual->point
  "Map visual row/col to byte offset."
  [state row col]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def width (state :width))
  (def vlines (compute-visual-lines content width))

  (when (empty? vlines)
    (break 0))

  (def clamped-row (min row (- (length vlines) 1)))
  (def vl (get vlines clamped-row))
  (def seg-len (- (vl :end) (vl :start)))
  (def clamped-col (min col seg-len))
  (+ (vl :start) clamped-col))

# ── Constructor + Queries ────────────────────────────────────

(defn new
  "Create a new editor state wrapping a fresh gent buffer."
  [width height &opt initial-text]
  (default initial-text "")
  (def name (string "*editor-" (++ next-id) "*"))
  (def buf (buffers/create name initial-text))
  (when (> (length initial-text) 0)
    (buffers/set-point buf (length initial-text)))
  @{:buf buf
    :scroll 0
    :width width
    :height height
    :sticky-col nil
    :undo @[]
    :redo @[]
    :kill-ring @[]
    :last-yank nil})

(defn text
  "Get the full text as a string."
  [state]
  (buffers/string-content (state :buf)))

(defn point
  "Get the byte offset cursor position."
  [state]
  (buffers/get-point (state :buf)))

(defn line-col
  "Get {:line :col} computed from point."
  [state]
  (def content (buffers/string-content (state :buf)))
  (point->line-col content (buffers/get-point (state :buf))))

(defn cursor-visual
  "Get {:row :col} in viewport coordinates."
  [state]
  (def vis (point->visual state))
  {:row (- (vis :row) (state :scroll))
   :col (vis :col)})

# ── Undo Infrastructure ─────────────────────────────────────

(defn- snapshot
  "Take a snapshot of current buffer state for undo."
  [state]
  (def buf (state :buf))
  (array/push (state :undo)
    {:content (buffers/string-content buf)
     :point (buffers/get-point buf)})
  (array/clear (state :redo)))

(defn undo
  "Restore previous content + point snapshot."
  [state]
  (def undo-stack (state :undo))
  (when (empty? undo-stack)
    (break state))
  (def buf (state :buf))
  (def current {:content (buffers/string-content buf)
                :point (buffers/get-point buf)})
  (array/push (state :redo) current)
  (def snap (array/pop undo-stack))
  (def c (buf :content))
  (buffer/clear c)
  (buffer/push c (snap :content))
  (buffers/set-point buf (snap :point))
  (put state :sticky-col nil)
  (put state :last-yank nil)
  state)

(defn redo
  "Re-apply undone snapshot."
  [state]
  (def redo-stack (state :redo))
  (when (empty? redo-stack)
    (break state))
  (def buf (state :buf))
  (def current {:content (buffers/string-content buf)
                :point (buffers/get-point buf)})
  (array/push (state :undo) current)
  (def snap (array/pop redo-stack))
  (def c (buf :content))
  (buffer/clear c)
  (buffer/push c (snap :content))
  (buffers/set-point buf (snap :point))
  (put state :sticky-col nil)
  (put state :last-yank nil)
  state)

# ── Scrolling ────────────────────────────────────────────────

(defn- ensure-cursor-visible
  "Adjust scroll so cursor's visual row is within the viewport."
  [state]
  (def vis (point->visual state))
  (def row (vis :row))
  (def scroll (state :scroll))
  (def height (state :height))
  (when (< row scroll)
    (put state :scroll row))
  (when (>= row (+ scroll height))
    (put state :scroll (- row height -1)))
  state)

# ── Basic Insert/Delete ──────────────────────────────────────

(defn insert-char
  "Insert a character at point."
  [state ch]
  (snapshot state)
  (def buf (state :buf))
  (buffers/insert buf (buffers/get-point buf) ch)
  (put state :sticky-col nil)
  (put state :last-yank nil)
  (ensure-cursor-visible state))

(defn insert-newline
  "Insert a newline at point."
  [state]
  (snapshot state)
  (def buf (state :buf))
  (buffers/insert buf (buffers/get-point buf) "\n")
  (put state :sticky-col nil)
  (put state :last-yank nil)
  (ensure-cursor-visible state))

(defn delete-back
  "Delete one byte before point."
  [state]
  (def buf (state :buf))
  (def pt (buffers/get-point buf))
  (when (> pt 0)
    (snapshot state)
    (buffers/delete buf (- pt 1) pt)
    (put state :sticky-col nil)
    (put state :last-yank nil)
    (ensure-cursor-visible state))
  state)

(defn delete-forward
  "Delete one byte after point."
  [state]
  (def buf (state :buf))
  (def pt (buffers/get-point buf))
  (def content (buffers/string-content buf))
  (when (< pt (length content))
    (snapshot state)
    (buffers/delete buf pt (+ pt 1))
    (put state :sticky-col nil)
    (put state :last-yank nil)
    (ensure-cursor-visible state))
  state)

# ── Horizontal Movement ─────────────────────────────────────

(defn move-left
  "Move point one byte left."
  [state]
  (def buf (state :buf))
  (def pt (buffers/get-point buf))
  (when (> pt 0)
    (buffers/set-point buf (- pt 1)))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn move-right
  "Move point one byte right."
  [state]
  (def buf (state :buf))
  (def pt (buffers/get-point buf))
  (def content (buffers/string-content buf))
  (when (< pt (length content))
    (buffers/set-point buf (+ pt 1)))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn move-line-start
  "Move point to start of current logical line."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def lc (point->line-col content (buffers/get-point buf)))
  (buffers/set-point buf (line-start-offset content (lc :line)))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn move-line-end
  "Move point to end of current logical line."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def lc (point->line-col content (buffers/get-point buf)))
  (buffers/set-point buf (line-end-offset content (lc :line)))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn move-buffer-start
  "Move point to start of buffer."
  [state]
  (buffers/set-point (state :buf) 0)
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn move-buffer-end
  "Move point to end of buffer."
  [state]
  (def buf (state :buf))
  (buffers/set-point buf (length (buffers/string-content buf)))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

# ── Word Operations ──────────────────────────────────────────

(defn- word-char? [ch]
  (and (not= ch (chr " "))
       (not= ch (chr "\n"))
       (not= ch (chr "\t"))))

(defn- find-word-start-back
  "Find the start of the previous word from position."
  [content pos]
  (var p pos)
  (while (and (> p 0) (not (word-char? (get content (- p 1)))))
    (-- p))
  (while (and (> p 0) (word-char? (get content (- p 1))))
    (-- p))
  p)

(defn- find-next-word-start
  "Skip past current word and following whitespace (readline-style forward-word)."
  [content pos]
  (var p pos)
  (def len (length content))
  (while (and (< p len) (word-char? (get content p)))
    (++ p))
  (while (and (< p len) (not (word-char? (get content p))))
    (++ p))
  p)

(defn- find-word-end-forward
  "Skip whitespace then word-chars (emacs M-d style kill-word)."
  [content pos]
  (var p pos)
  (def len (length content))
  (while (and (< p len) (not (word-char? (get content p))))
    (++ p))
  (while (and (< p len) (word-char? (get content p)))
    (++ p))
  p)

(defn move-word-left
  "Move point to start of previous word."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def pt (buffers/get-point buf))
  (buffers/set-point buf (find-word-start-back content pt))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn move-word-right
  "Move point past current word and following whitespace."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def pt (buffers/get-point buf))
  (buffers/set-point buf (find-next-word-start content pt))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn delete-word-back
  "Delete from word-start to point, push to kill ring."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def pt (buffers/get-point buf))
  (when (> pt 0)
    (def word-start (find-word-start-back content pt))
    (when (< word-start pt)
      (snapshot state)
      (def killed (string/slice content word-start pt))
      (array/push (state :kill-ring) killed)
      (when (> (length (state :kill-ring)) 30)
        (array/remove (state :kill-ring) 0))
      (buffers/delete buf word-start pt)
      (put state :sticky-col nil)
      (put state :last-yank nil)
      (ensure-cursor-visible state)))
  state)

(defn delete-word-forward
  "Delete from point to word-end, push to kill ring."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def pt (buffers/get-point buf))
  (when (< pt (length content))
    (def word-end (find-word-end-forward content pt))
    (when (> word-end pt)
      (snapshot state)
      (def killed (string/slice content pt word-end))
      (array/push (state :kill-ring) killed)
      (when (> (length (state :kill-ring)) 30)
        (array/remove (state :kill-ring) 0))
      (buffers/delete buf pt word-end)
      (put state :sticky-col nil)
      (put state :last-yank nil)
      (ensure-cursor-visible state)))
  state)

# ── Kill/Yank ────────────────────────────────────────────────

(defn kill-to-end
  "Kill from point to newline. At line end: join lines."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def pt (buffers/get-point buf))
  (def lc (point->line-col content pt))
  (def end (line-end-offset content (lc :line)))
  (snapshot state)
  (if (= pt end)
    (when (< pt (length content))
      (def killed (string/slice content pt (+ pt 1)))
      (array/push (state :kill-ring) killed)
      (when (> (length (state :kill-ring)) 30)
        (array/remove (state :kill-ring) 0))
      (buffers/delete buf pt (+ pt 1)))
    (do
      (def killed (string/slice content pt end))
      (array/push (state :kill-ring) killed)
      (when (> (length (state :kill-ring)) 30)
        (array/remove (state :kill-ring) 0))
      (buffers/delete buf pt end)))
  (put state :sticky-col nil)
  (put state :last-yank nil)
  (ensure-cursor-visible state))

(defn kill-to-start
  "Kill from line-start to point."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def pt (buffers/get-point buf))
  (def lc (point->line-col content pt))
  (def start (line-start-offset content (lc :line)))
  (when (> pt start)
    (snapshot state)
    (def killed (string/slice content start pt))
    (array/push (state :kill-ring) killed)
    (when (> (length (state :kill-ring)) 30)
      (array/remove (state :kill-ring) 0))
    (buffers/delete buf start pt)
    (put state :sticky-col nil)
    (put state :last-yank nil)
    (ensure-cursor-visible state))
  state)

(defn yank
  "Insert most recent kill-ring entry at point."
  [state]
  (def kr (state :kill-ring))
  (when (empty? kr)
    (break state))
  (snapshot state)
  (def entry (last kr))
  (def buf (state :buf))
  (buffers/insert buf (buffers/get-point buf) entry)
  (put state :last-yank (length entry))
  (put state :sticky-col nil)
  (ensure-cursor-visible state))

(defn yank-pop
  "Replace just-yanked text with previous kill-ring entry."
  [state]
  (def last-len (state :last-yank))
  (when (nil? last-len)
    (break state))
  (def kr (state :kill-ring))
  (when (< (length kr) 2)
    (break state))
  (def buf (state :buf))
  (def pt (buffers/get-point buf))
  # Remove the last yank
  (buffers/delete buf (- pt last-len) pt)
  # Rotate kill ring: move last to front
  (def prev (array/pop kr))
  (array/insert kr 0 prev)
  # Insert the new last entry
  (def entry (last kr))
  (buffers/insert buf (buffers/get-point buf) entry)
  (put state :last-yank (length entry))
  (ensure-cursor-visible state))

# ── Vertical Movement ────────────────────────────────────────

(defn move-up
  "Move one visual row up, preserving sticky-col."
  [state]
  (def vis (point->visual state))
  (def row (vis :row))
  (when (> row 0)
    (def col (or (state :sticky-col) (vis :col)))
    (when (nil? (state :sticky-col))
      (put state :sticky-col col))
    (def new-pt (visual->point state (- row 1) col))
    (buffers/set-point (state :buf) new-pt)
    (ensure-cursor-visible state))
  state)

(defn move-down
  "Move one visual row down, preserving sticky-col."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def vis (point->visual state))
  (def row (vis :row))
  (def vlines (compute-visual-lines content (state :width)))
  (when (< row (- (length vlines) 1))
    (def col (or (state :sticky-col) (vis :col)))
    (when (nil? (state :sticky-col))
      (put state :sticky-col col))
    (def new-pt (visual->point state (+ row 1) col))
    (buffers/set-point buf new-pt)
    (ensure-cursor-visible state))
  state)

(defn page-up
  "Move cursor up by viewport height."
  [state]
  (def vis (point->visual state))
  (def col (or (state :sticky-col) (vis :col)))
  (when (nil? (state :sticky-col))
    (put state :sticky-col col))
  (def target-row (max 0 (- (vis :row) (state :height))))
  (def new-pt (visual->point state target-row col))
  (buffers/set-point (state :buf) new-pt)
  (ensure-cursor-visible state))

(defn page-down
  "Move cursor down by viewport height."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def vlines (compute-visual-lines content (state :width)))
  (def vis (point->visual state))
  (def col (or (state :sticky-col) (vis :col)))
  (when (nil? (state :sticky-col))
    (put state :sticky-col col))
  (def max-row (- (length vlines) 1))
  (def target-row (min max-row (+ (vis :row) (state :height))))
  (def new-pt (visual->point state target-row col))
  (buffers/set-point buf new-pt)
  (ensure-cursor-visible state))

# ── Rendering ────────────────────────────────────────────────

(defn render
  "Render the editor viewport. Returns {:lines [...] :cursor {:row :col}}."
  [state]
  (def buf (state :buf))
  (def content (buffers/string-content buf))
  (def width (state :width))
  (def height (state :height))
  (def scroll (state :scroll))
  (def vlines (compute-visual-lines content width))

  (def visible @[])
  (for i scroll (min (+ scroll height) (length vlines))
    (array/push visible (get-in vlines [i :text])))

  # Pad with empty strings if fewer visual lines than viewport
  (while (< (length visible) height)
    (array/push visible ""))

  (def vis (point->visual state))
  {:lines visible
   :cursor {:row (- (vis :row) scroll)
            :col (vis :col)}})

# ── Bulk Operations ──────────────────────────────────────────

(defn insert-text
  "Insert multi-line text at point."
  [state txt]
  (snapshot state)
  (def buf (state :buf))
  (buffers/insert buf (buffers/get-point buf) txt)
  (put state :sticky-col nil)
  (put state :last-yank nil)
  (ensure-cursor-visible state))

(defn set-text
  "Clear buffer and insert new content."
  [state txt]
  (snapshot state)
  (def buf (state :buf))
  (def c (buf :content))
  (def len (length c))
  (when (> len 0)
    (buffers/delete buf 0 len))
  (when (> (length txt) 0)
    (buffers/insert buf 0 txt))
  (put state :sticky-col nil)
  (put state :last-yank nil)
  (ensure-cursor-visible state))

(defn open-external
  "Return sentinel for widget layer to open $EDITOR."
  [state]
  {:action :open-external :text (text state)})

# ── Resize ───────────────────────────────────────────────────

(defn resize
  "Update viewport dimensions. Recompute scroll."
  [state w h]
  (put state :width w)
  (put state :height h)
  (ensure-cursor-visible state))

# ── Key Dispatch ─────────────────────────────────────────────

(defn handle-key
  "Dispatch a key event to the appropriate command.
   Returns state for normal commands, or a special value for
   submit/external-editor signals."
  [state ev]
  (def key (ev :key))
  (def ctrl (get ev :ctrl false))
  (def alt (get ev :alt false))
  (def shift (get ev :shift false))

  (cond
    # Alt+Enter or Shift+Enter: insert newline
    (and (or alt shift) (= key :enter))
    (insert-newline state)

    # Ctrl+G: open external editor
    (and ctrl (= key "g"))
    (open-external state)

    # Ctrl+Z: undo
    (and ctrl (not shift) (= key "z"))
    (undo state)

    # Ctrl+Shift+Z: redo
    (and ctrl shift (= key "z"))
    (redo state)

    # Ctrl+Y: yank
    (and ctrl (= key "y"))
    (yank state)

    # Alt+Y: yank-pop
    (and alt (= key "y"))
    (yank-pop state)

    # Ctrl+K: kill to end
    (and ctrl (= key "k"))
    (kill-to-end state)

    # Ctrl+U: kill to start
    (and ctrl (= key "u"))
    (kill-to-start state)

    # Ctrl+W / Alt+Backspace / Ctrl+Backspace: delete word back
    (and ctrl (= key "w"))
    (delete-word-back state)

    (and alt (= key :backspace))
    (delete-word-back state)

    (and ctrl (= key :backspace))
    (delete-word-back state)

    # Alt+D: delete word forward
    (and alt (= key "d"))
    (delete-word-forward state)

    # Ctrl+D: delete forward
    (and ctrl (= key "d"))
    (delete-forward state)

    # Movement: Ctrl+A / Home
    (and ctrl (= key "a"))
    (move-line-start state)

    (= key :home)
    (if ctrl
      (move-buffer-start state)
      (move-line-start state))

    # Movement: Ctrl+E / End
    (and ctrl (= key "e"))
    (move-line-end state)

    (= key :end)
    (if ctrl
      (move-buffer-end state)
      (move-line-end state))

    # Movement: Ctrl+B / Left
    (and ctrl (= key "b"))
    (move-left state)

    (= key :left)
    (if alt
      (move-word-left state)
      (move-left state))

    # Movement: Ctrl+F / Right
    (and ctrl (= key "f"))
    (move-right state)

    (= key :right)
    (if alt
      (move-word-right state)
      (move-right state))

    # Alt+B / Alt+F: word movement
    (and alt (= key "b"))
    (move-word-left state)

    (and alt (= key "f"))
    (move-word-right state)

    # Vertical: Ctrl+P / Up
    (and ctrl (= key "p"))
    (move-up state)

    (= key :up)
    (move-up state)

    # Vertical: Ctrl+N / Down
    (and ctrl (= key "n"))
    (move-down state)

    (= key :down)
    (move-down state)

    # Page Up/Down
    (= key :page-up)
    (page-up state)

    (= key :page-down)
    (page-down state)

    # Ctrl+Home / Ctrl+End
    # (handled above via :home/:end with ctrl check)

    # Backspace
    (= key :backspace)
    (delete-back state)

    # Delete
    (= key :delete)
    (delete-forward state)

    # Regular character
    (string? key)
    (insert-char state key)

    # Unknown key — no-op
    state))
