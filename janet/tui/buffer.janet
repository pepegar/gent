# tui/buffer.janet — 2D grid of styled cells.
#
# A Buffer is the render target for all widgets. Each cell holds a character
# and a style. After rendering, convert to an ANSI string with buffer->str.
#
# Usage:
#   (def buf (buffer (rect 0 0 80 24)))
#   (buffer-set-char buf 5 3 "X" (style :fg :red))
#   (buffer-set-string buf 0 0 "Hello" (style :bold true))
#   (print (buffer->str buf))

(use ./rect)
(use ./style)
(use ./charwidth)

# ── Cell ───────────────────────────────────────────────────────

(defn cell
  "Create a cell with a character and style."
  [ch &opt st]
  (default st style-default)
  {:ch ch :style st})

(def cell-empty
  "A blank cell (space, no style)."
  {:ch " " :style style-default})

# ── Buffer ─────────────────────────────────────────────────────

(defn buffer
  "Create a buffer for the given rect, filled with empty cells.
   When track-dirty is true, adds a :dirty-rows array for row-level change tracking."
  [area &opt track-dirty]
  (def n (rect-area area))
  (def cells (array/new n))
  (for _ 0 n (array/push cells @{:ch " " :style style-default}))
  (def buf @{:area area :cells cells})
  (when track-dirty
    (def h (area :height))
    (def dr (array/new h))
    (for _ 0 h (array/push dr true))
    (put buf :dirty-rows dr))
  buf)

(defn buffer-clear
  [buf]
  (def cells (buf :cells))
  (each c cells
    (put c :ch " ")
    (put c :style style-default))
  (when-let [dr (buf :dirty-rows)]
    (for i 0 (length dr) (put dr i true)))
  buf)

(defn- buf-idx
  "Compute the flat index for (x, y) within a buffer."
  [buf x y]
  (def a (buf :area))
  (+ (* (- y (a :y)) (a :width))
     (- x (a :x))))

(defn buffer-get
  "Get the cell at (x, y). Returns cell-empty if out of bounds."
  [buf x y]
  (def a (buf :area))
  (if (and (>= x (a :x)) (< x (rect-right a))
           (>= y (a :y)) (< y (rect-bottom a)))
    (get (buf :cells) (buf-idx buf x y))
    cell-empty))

(defn buffer-set-char
  "Set a single character at (x, y) with optional style."
  [buf x y ch &opt st]
  (default st style-default)
  (def a (buf :area))
  (when (and (>= x (a :x)) (< x (rect-right a))
             (>= y (a :y)) (< y (rect-bottom a)))
    (def c (get (buf :cells) (buf-idx buf x y)))
    (put c :ch ch)
    (put c :style st)
    (when-let [dr (buf :dirty-rows)]
      (def row (- y (a :y)))
      (when (< row (length dr))
        (put dr row true)))))

(defn buffer-set-string
  "Write a string horizontally starting at (x, y). Handles UTF-8 and wide chars. Clips to buffer bounds."
  [buf x y text &opt st]
  (default st style-default)
  (var col x)
  (var i 0)
  (def len (length text))
  (def a (buf :area))
  (def right (rect-right a))
  (while (< i len)
    (def byte (get text i))
    # Skip newlines and other control characters - they shouldn't be rendered
    (if (or (= byte 10) (= byte 13) (< byte 32))
      (++ i)
      (do
        # Determine UTF-8 character length from lead byte
        (def char-len
          (cond
            (< byte 0x80) 1
            (< byte 0xE0) 2
            (< byte 0xF0) 3
            4))
        (def end (min (+ i char-len) len))
        (def ch (string/slice text i end))
        (def w (char-width ch))
        (if (= w 0)
          (do
            # Zero-width char (combining mark, variation selector, etc.):
            # Append to the previous visible cell so the terminal renders them together.
            # For wide chars, the previous visible cell might be 2 columns back (skip continuation).
            (when (> col x)
              (var prev-col (- col 1))
              (var prev-cell (get (buf :cells) (buf-idx buf prev-col y)))
              (when (and prev-cell (= (prev-cell :ch) "") (> prev-col x))
                # Hit a wide-char continuation cell — go one more back to the base char
                (set prev-col (- prev-col 1))
                (set prev-cell (get (buf :cells) (buf-idx buf prev-col y))))
              (when prev-cell
                (put prev-cell :ch (string (prev-cell :ch) ch))))
            (set i end))
          (do
            # Check if char fits (wide chars need 2 columns)
            (when (> (+ col w) right) (break))
            (buffer-set-char buf col y ch st)
            (when (= w 2)
              # Wide char: fill continuation cell
              (when (< (+ col 1) right)
                (buffer-set-char buf (+ col 1) y "" st)))
            (+= col w)
            (set i end)))))))

(defn buffer-set-style
  "Apply a style to all cells within a rect (merged on top of existing)."
  [buf area st]
  (def clipped (rect-intersection area (buf :area)))
  (when (not (rect-empty? clipped))
    (def ba (buf :area))
    (for y (clipped :y) (rect-bottom clipped)
      (for x (clipped :x) (rect-right clipped)
        (def c (get (buf :cells) (buf-idx buf x y)))
        (put c :style (style-merge (c :style) st)))
      (when-let [dr (buf :dirty-rows)]
        (def row (- y (ba :y)))
        (when (< row (length dr))
          (put dr row true))))))

(defn buffer-fill
  "Fill a rect with a character and style."
  [buf area ch &opt st]
  (default st style-default)
  (def clipped (rect-intersection area (buf :area)))
  (when (not (rect-empty? clipped))
    (for y (clipped :y) (rect-bottom clipped)
      (for x (clipped :x) (rect-right clipped)
        (buffer-set-char buf x y ch st)))))

# ── Plain text extraction (snapshot testing) ──────────────────

(defn buffer-to-plain-rows
  "Convert the buffer to an array of plain text strings (no ANSI escapes).
   Trailing spaces are trimmed from each row. Useful for snapshot testing.
   Handles wide chars: skips continuation cells (empty ch)."
  [buf]
  (def a (buf :area))
  (def rows @[])
  (for row 0 (a :height)
    (def chars @[])
    (for col 0 (a :width)
      (def c (buffer-get buf (+ (a :x) col) (+ (a :y) row)))
      (def ch (c :ch))
      (if (= ch "")
        nil  # skip continuation cell
        (array/push chars ch)))
    (array/push rows (string/trimr (string ;chars))))
  rows)

(defn buffer-to-text
  "Convert the buffer to a plain text string with rows joined by newlines.
   Trailing spaces are trimmed per row. Useful for snapshot testing."
  [buf]
  (string/join (buffer-to-plain-rows buf) "\n"))

# ── Buffer diffing ─────────────────────────────────────────────

(defn buffer-diff
  "Compare two buffers cell-by-cell. Returns an ANSI string that updates
   only the changed cells. Both buffers must cover the same area.
   Handles wide characters: skips continuation cells (empty ch) and
   accounts for wide chars advancing the cursor by 2.
   Emits OSC 8 hyperlink sequences for cells with :link in their style."
  [old-buf new-buf]
  (def a (new-buf :area))
  (def parts @[])
  (var cur-style nil)
  (var cur-link nil)

  (for row 0 (a :height)
    (var expected-col nil)
    (var col 0)
    (while (< col (a :width))
      (def x (+ (a :x) col))
      (def y (+ (a :y) row))
      (def old-cell (buffer-get old-buf x y))
      (def new-cell (buffer-get new-buf x y))
      (def ch (new-cell :ch))
      (def is-continuation (= ch ""))
      (if is-continuation
        (do
          # Wide char continuation cell — skip, the wide char already covers this
          (++ col))
        (do
          (unless (and (= (old-cell :ch) ch)
                       (style= (old-cell :style) (new-cell :style)))
            # Cell changed — emit cursor move if not at expected position
            (when (or (nil? expected-col) (not= col expected-col))
              # Close any open link before jumping cursor
              (when cur-link
                (array/push parts osc8-close)
                (set cur-link nil))
              (array/push parts
                (string/format "\x1b[%d;%dH" (+ y 1) (+ x 1))))
            (def st (new-cell :style))
            (when (not (style= st cur-style))
              (array/push parts "\x1b[0m")
              (def sgr (style->sgr st))
              (when (not= sgr "") (array/push parts sgr))
              (set cur-style st))
            # Handle link transitions
            (def new-link (get st :link))
            (when (not= cur-link new-link)
              (when cur-link (array/push parts osc8-close))
              (when new-link (array/push parts (osc8-open new-link)))
              (set cur-link new-link))
            (array/push parts ch)
            # Wide chars advance cursor by 2
            (def w (char-width ch))
            (set expected-col (+ col w)))
          (def w (char-width ch))
          (set col (+ col (if (> w 0) w 1)))))))

  (when cur-link (array/push parts osc8-close))
  (when (not (empty? parts))
    (array/push parts "\x1b[0m"))
  (string ;parts))

# ── ANSI rendering ─────────────────────────────────────────────

(defn buffer->str
  "Convert the entire buffer to an ANSI escape-coded string.
   Moves the cursor to each row and emits style changes as needed.
   Handles wide characters: skips continuation cells.
   Emits OSC 8 hyperlink sequences for cells with :link in their style."
  [buf]
  (def parts @[])
  (def a (buf :area))
  (var cur-style nil)
  (var cur-link nil)

  (for row 0 (a :height)
    # Close any open link before moving cursor to new row
    (when cur-link
      (array/push parts osc8-close)
      (set cur-link nil))
    # Move cursor to start of row (ANSI is 1-indexed)
    (array/push parts
      (string/format "\x1b[%d;%dH" (+ (a :y) row 1) (+ (a :x) 1)))
    (var col 0)
    (while (< col (a :width))
      (def c (buffer-get buf (+ (a :x) col) (+ (a :y) row)))
      (def ch (c :ch))
      (if (= ch "")
        # Wide char continuation — skip
        (++ col)
        (do
          (def st (c :style))
          (when (not (style= st cur-style))
            (array/push parts "\x1b[0m")
            (def sgr (style->sgr st))
            (when (not= sgr "") (array/push parts sgr))
            (set cur-style st))
          # Handle link transitions
          (def new-link (get st :link))
          (when (not= cur-link new-link)
            (when cur-link (array/push parts osc8-close))
            (when new-link (array/push parts (osc8-open new-link)))
            (set cur-link new-link))
          (array/push parts ch)
          (def w (char-width ch))
          (set col (+ col (if (> w 0) w 1)))))))

  (when cur-link (array/push parts osc8-close))
  (array/push parts "\x1b[0m")
  (string ;parts))

(defn buffer->rows
  "Convert the buffer to an array of ANSI-styled row strings (no cursor movement).
   Each element is one row, ready to be printed line-by-line.
   Handles wide characters: skips continuation cells.
   Emits OSC 8 hyperlink sequences for cells with :link in their style."
  [buf]
  (def a (buf :area))
  (def rows @[])

  (for row 0 (a :height)
    (def parts @[])
    (var cur-style nil)
    (var cur-link nil)
    (var col 0)
    (while (< col (a :width))
      (def c (buffer-get buf (+ (a :x) col) (+ (a :y) row)))
      (def ch (c :ch))
      (if (= ch "")
        # Wide char continuation — skip
        (++ col)
        (do
          (def st (c :style))
          (when (not (style= st cur-style))
            (array/push parts "\x1b[0m")
            (def sgr (style->sgr st))
            (when (not= sgr "") (array/push parts sgr))
            (set cur-style st))
          # Handle link transitions
          (def new-link (get st :link))
          (when (not= cur-link new-link)
            (when cur-link (array/push parts osc8-close))
            (when new-link (array/push parts (osc8-open new-link)))
            (set cur-link new-link))
          (array/push parts ch)
          (def w (char-width ch))
          (set col (+ col (if (> w 0) w 1))))))
    (when cur-link (array/push parts osc8-close))
    (array/push parts "\x1b[0m")
    (array/push rows (string ;parts)))

  rows)
