# tui/rect.janet — Rectangular area on screen.
#
# A Rect represents a positioned, sized rectangle in terminal coordinates.
# Origin (0,0) is top-left. Rects are immutable structs.
#
# Usage:
#   (def area (rect 0 0 80 24))
#   (rect-right area)      # => 80
#   (rect-bottom area)     # => 24
#   (rect-inner area (padding 1 1 1 1))

(defn rect
  "Create a rectangle at (x, y) with given width and height."
  [x y width height]
  (struct :x x :y y :width width :height height))

(def rect-zero
  "A zero-sized rect at the origin."
  (rect 0 0 0 0))

(defn rect-right
  "Right edge (exclusive): x + width."
  [r]
  (+ (r :x) (r :width)))

(defn rect-bottom
  "Bottom edge (exclusive): y + height."
  [r]
  (+ (r :y) (r :height)))

(defn rect-area
  "Total cell count: width * height."
  [r]
  (* (r :width) (r :height)))

(defn rect-empty?
  "True if the rect has zero area."
  [r]
  (or (<= (r :width) 0) (<= (r :height) 0)))

(defn rect-intersection
  "Return the overlapping region of two rects, or rect-zero."
  [a b]
  (def x (max (a :x) (b :x)))
  (def y (max (a :y) (b :y)))
  (def r (min (rect-right a) (rect-right b)))
  (def bot (min (rect-bottom a) (rect-bottom b)))
  (def w (max 0 (- r x)))
  (def h (max 0 (- bot y)))
  (if (or (<= w 0) (<= h 0))
    rect-zero
    (rect x y w h)))

(defn rect-contains?
  "True if point (px, py) is inside the rect."
  [r px py]
  (and (>= px (r :x))
       (< px (rect-right r))
       (>= py (r :y))
       (< py (rect-bottom r))))

(defn rect-inner
  "Shrink a rect by a padding {:left :right :top :bottom}."
  [r pad]
  (def x (+ (r :x) (or (pad :left) 0)))
  (def y (+ (r :y) (or (pad :top) 0)))
  (def w (- (r :width) (or (pad :left) 0) (or (pad :right) 0)))
  (def h (- (r :height) (or (pad :top) 0) (or (pad :bottom) 0)))
  (rect (max x (r :x))
        (max y (r :y))
        (max 0 w)
        (max 0 h)))
