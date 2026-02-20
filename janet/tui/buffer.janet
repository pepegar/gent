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
  "Write a string horizontally starting at (x, y). Clips to buffer bounds."
  [buf x y text &opt st]
  (default st style-default)
  (var col x)
  (each byte text
    (buffer-set-char buf col y (string/from-bytes byte) st)
    (++ col)))

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
      (when (not (deep= st cur-style))
        (array/push parts "\x1b[0m")
        (def sgr (style->sgr st))
        (when (not= sgr "") (array/push parts sgr))
        (set cur-style st))
      (array/push parts (c :ch))))

  (array/push parts "\x1b[0m")
  (string ;parts))
