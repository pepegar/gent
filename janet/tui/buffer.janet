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
  "Create a buffer for the given rect, filled with empty cells."
  [area]
  (def n (rect-area area))
  (def cells (array/new n))
  (for _ 0 n (array/push cells @{:ch " " :style style-default}))
  @{:area area :cells cells})

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
    (put c :style st)))

(defn buffer-set-string
  "Write a string horizontally starting at (x, y). Handles UTF-8. Clips to buffer bounds."
  [buf x y text &opt st]
  (default st style-default)
  (var col x)
  (var i 0)
  (def len (length text))
  (while (< i len)
    (def byte (get text i))
    # Determine UTF-8 character length from lead byte
    (def char-len
      (cond
        (< byte 0x80) 1
        (< byte 0xE0) 2
        (< byte 0xF0) 3
        4))
    (def end (min (+ i char-len) len))
    (def ch (string/slice text i end))
    (buffer-set-char buf col y ch st)
    (++ col)
    (set i end)))

(defn buffer-set-style
  "Apply a style to all cells within a rect (merged on top of existing)."
  [buf area st]
  (def clipped (rect-intersection area (buf :area)))
  (when (not (rect-empty? clipped))
    (for y (clipped :y) (rect-bottom clipped)
      (for x (clipped :x) (rect-right clipped)
        (def c (get (buf :cells) (buf-idx buf x y)))
        (put c :style (style-merge (c :style) st))))))

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
   Trailing spaces are trimmed from each row. Useful for snapshot testing."
  [buf]
  (def a (buf :area))
  (def rows @[])
  (for row 0 (a :height)
    (def chars @[])
    (for col 0 (a :width)
      (def c (buffer-get buf (+ (a :x) col) (+ (a :y) row)))
      (array/push chars (c :ch)))
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
   only the changed cells. Both buffers must cover the same area."
  [old-buf new-buf]
  (def a (new-buf :area))
  (def parts @[])
  (var cur-style nil)

  (for row 0 (a :height)
    (var expected-col nil)
    (for col 0 (a :width)
      (def x (+ (a :x) col))
      (def y (+ (a :y) row))
      (def old-cell (buffer-get old-buf x y))
      (def new-cell (buffer-get new-buf x y))
      (unless (and (= (old-cell :ch) (new-cell :ch))
                   (style= (old-cell :style) (new-cell :style)))
        # Cell changed — emit cursor move if not at expected position
        (when (or (nil? expected-col) (not= col expected-col))
          (array/push parts
            (string/format "\x1b[%d;%dH" (+ y 1) (+ x 1))))
        (def st (new-cell :style))
        (when (not (style= st cur-style))
          (array/push parts "\x1b[0m")
          (def sgr (style->sgr st))
          (when (not= sgr "") (array/push parts sgr))
          (set cur-style st))
        (array/push parts (new-cell :ch))
        (set expected-col (+ col 1)))))

  (when (not (empty? parts))
    (array/push parts "\x1b[0m"))
  (string ;parts))

# ── ANSI rendering ─────────────────────────────────────────────

(defn buffer->str
  "Convert the entire buffer to an ANSI escape-coded string.
   Moves the cursor to each row and emits style changes as needed."
  [buf]
  (def parts @[])
  (def a (buf :area))
  (var cur-style nil)

  (for row 0 (a :height)
    # Move cursor to start of row (ANSI is 1-indexed)
    (array/push parts
      (string/format "\x1b[%d;%dH" (+ (a :y) row 1) (+ (a :x) 1)))
    (for col 0 (a :width)
      (def c (buffer-get buf (+ (a :x) col) (+ (a :y) row)))
      (def st (c :style))
      (when (not (style= st cur-style))
        (array/push parts "\x1b[0m")
        (def sgr (style->sgr st))
        (when (not= sgr "") (array/push parts sgr))
        (set cur-style st))
      (array/push parts (c :ch))))

  (array/push parts "\x1b[0m")
  (string ;parts))

(defn buffer->rows
  "Convert the buffer to an array of ANSI-styled row strings (no cursor movement).
   Each element is one row, ready to be printed line-by-line."
  [buf]
  (def a (buf :area))
  (def rows @[])

  (for row 0 (a :height)
    (def parts @[])
    (var cur-style nil)
    (for col 0 (a :width)
      (def c (buffer-get buf (+ (a :x) col) (+ (a :y) row)))
      (def st (c :style))
      (when (not (style= st cur-style))
        (array/push parts "\x1b[0m")
        (def sgr (style->sgr st))
        (when (not= sgr "") (array/push parts sgr))
        (set cur-style st))
      (array/push parts (c :ch)))
    (array/push parts "\x1b[0m")
    (array/push rows (string ;parts)))

  rows)
