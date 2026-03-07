# tui/block.janet — Block widget: borders, padding, title.
#
# The fundamental container widget. Draws borders around a region,
# adds optional padding, and renders an optional title.
#
# Usage:
#   (def b (block :title "Hello"
#                 :borders :all
#                 :border-type :rounded
#                 :border-style (style :fg :cyan)
#                 :padding (padding 1 1 1 1)))
#   (render b area buf)
#   (def inner (block-inner b area))   # area available for content

(use ./rect)
(use ./style)
(use ./buffer)
(use ./charwidth)

# ── Padding ────────────────────────────────────────────────────

(defn padding
  "Create padding {left right top bottom}."
  [left right top bottom]
  (struct :left left :right right :top top :bottom bottom))

(def padding-zero
  "No padding."
  (padding 0 0 0 0))

(defn padding-uniform
  "Equal padding on all sides."
  [n]
  (padding n n n n))

(defn padding-symmetric
  "Symmetric padding: x for left/right, y for top/bottom."
  [x y]
  (padding x x y y))

(defn padding-horizontal
  "Padding on left and right only."
  [n]
  (padding n n 0 0))

(defn padding-vertical
  "Padding on top and bottom only."
  [n]
  (padding 0 0 n n))

# ── Border sets ────────────────────────────────────────────────

(def border-plain
  {:tl "┌" :t "─" :tr "┐"
   :l  "│"        :r  "│"
   :bl "└" :b "─" :br "┘"})

(def border-rounded
  {:tl "╭" :t "─" :tr "╮"
   :l  "│"        :r  "│"
   :bl "╰" :b "─" :br "╯"})

(def border-double
  {:tl "╔" :t "═" :tr "╗"
   :l  "║"        :r  "║"
   :bl "╚" :b "═" :br "╝"})

(def border-thick
  {:tl "┏" :t "━" :tr "┓"
   :l  "┃"        :r  "┃"
   :bl "┗" :b "━" :br "┛"})

(defn- border-set-for [type]
  (case type
    :plain   border-plain
    :rounded border-rounded
    :double  border-double
    :thick   border-thick
    border-plain))

# ── Border flags ───────────────────────────────────────────────

(defn- has-border? [borders side]
  (cond
    (= borders :all) true
    (= borders :none) false
    (keyword? borders) (= borders side)
    (indexed? borders) (some |(= $ side) borders)
    false))

# ── UTF-8-aware truncation ────────────────────────────────────

(defn- truncate-to-width [text max-w]
  "Truncate text to fit within max-w display columns, respecting UTF-8."
  (var col 0)
  (var i 0)
  (def len (length text))
  (while (< i len)
    (def b0 (get text i))
    (def char-len
      (cond (< b0 0x80) 1 (< b0 0xE0) 2 (< b0 0xF0) 3 4))
    (def end (min (+ i char-len) len))
    (def ch (string/slice text i end))
    (def w (char-width ch))
    (when (> (+ col w) max-w) (break))
    (+= col w)
    (set i end))
  (string/slice text 0 i))

# ── Block construction ─────────────────────────────────────────

(defn block
  "Create a block widget.
   Options:
     :title        string — title text
     :title-style  style  — style for the title
     :borders      :all | :none | :top | :bottom | :left | :right | [:top :bottom ...]
     :border-type  :plain | :rounded | :double | :thick
     :border-style style  — style for border characters
     :border-set   table  — custom border character set
     :padding      padding struct
     :style        style  — base style applied to entire block area"
  [& args]
  (def opts (table ;args))
  (put opts :borders (or (opts :borders) :none))
  (put opts :border-type (or (opts :border-type) :plain))
  (put opts :padding (or (opts :padding) padding-zero))
  (put opts :style (or (opts :style) style-default))
  (put opts :border-style (or (opts :border-style) style-default))
  (put opts :title-style (or (opts :title-style) style-default))
  (def bs (or (opts :border-set) (border-set-for (opts :border-type))))
  (put opts :border-set bs)
  (put opts :type :block)

  # Attach render method
  (put opts :render
    (fn [self area buf]
      (when (rect-empty? area) (break))
      (def borders (self :borders))
      (def bset (self :border-set))
      (def bst (self :border-style))
      (def base-st (self :style))

      # Apply base style to whole area
      (when (not= base-st style-default)
        (buffer-fill buf area " " base-st))

      (def left   (area :x))
      (def top    (area :y))
      (def right  (- (rect-right area) 1))
      (def bottom (- (rect-bottom area) 1))

      # Top border
      (when (has-border? borders :top)
        (for x (+ left 1) right
          (buffer-set-char buf x top (bset :t) bst))
        # Corners
        (when (has-border? borders :left)
          (buffer-set-char buf left top (bset :tl) bst))
        (when (has-border? borders :right)
          (buffer-set-char buf right top (bset :tr) bst)))

      # Bottom border
      (when (has-border? borders :bottom)
        (for x (+ left 1) right
          (buffer-set-char buf x bottom (bset :b) bst))
        (when (has-border? borders :left)
          (buffer-set-char buf left bottom (bset :bl) bst))
        (when (has-border? borders :right)
          (buffer-set-char buf right bottom (bset :br) bst)))

      # Left border
      (when (has-border? borders :left)
        (for y (+ top 1) bottom
          (buffer-set-char buf left y (bset :l) bst)))

      # Right border
      (when (has-border? borders :right)
        (for y (+ top 1) bottom
          (buffer-set-char buf right y (bset :r) bst)))

      # Title
      (when-let [title (self :title)]
        (def tst (style-merge bst (self :title-style)))
        (def tx (+ left (if (has-border? borders :left) 1 0)))
        (def ty top)
        (def max-w (- (rect-right area)
                      tx
                      (if (has-border? borders :right) 1 0)))
        (when (> max-w 0)
          # Render " Title " with spacing
          (def display (string " " title " "))
          (buffer-set-string buf tx ty
            (truncate-to-width display max-w)
            tst)))))
  opts)

# ── block-inner ────────────────────────────────────────────────

(defn block-inner
  "Compute the inner area of a block after borders, title, and padding."
  [blk area]
  (def borders (or (blk :borders) :none))
  (def pad (or (blk :padding) padding-zero))
  (var x (area :x))
  (var y (area :y))
  (var w (area :width))
  (var h (area :height))
  # Borders
  (when (has-border? borders :left)
    (++ x) (-- w))
  (when (has-border? borders :right)
    (-- w))
  (when (or (has-border? borders :top) (blk :title))
    (++ y) (-- h))
  (when (has-border? borders :bottom)
    (-- h))
  # Padding
  (+= x (pad :left))
  (+= y (pad :top))
  (-= w (+ (pad :left) (pad :right)))
  (-= h (+ (pad :top) (pad :bottom)))
  (rect (max x (area :x))
        (max y (area :y))
        (max 0 w)
        (max 0 h)))
