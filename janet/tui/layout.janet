# tui/layout.janet — Split rects into sub-regions.
#
# Provides vsplit (vertical stacking), hsplit (horizontal stacking),
# and resolve-layout (declarative 2-level layout) with a constraint system
# supporting fixed sizes, percentages, and :fill for remaining space.
#
# Usage:
#   (def [header body footer] (vsplit area 3 :fill 1))
#   (def [sidebar main]       (hsplit area 20 :fill))
#
# Declarative layout:
#   (resolve-layout @[{:constraint :fill
#                      :children [{:widget :chat :constraint :fill}]}
#                     {:widget :separator :constraint 1}
#                     {:widget :editor :constraint 5}]
#                   area)

(use ./rect)

(defn- eval-constraint
  "Evaluate a constraint. If it's a function, call it. Otherwise return as-is."
  [c]
  (if (function? c) (try (c) ([_] 0)) c))

(defn- resolve-constraints
  "Resolve a list of constraints against a total size.
   Constraints: integer (fixed size), float 0.0-1.0 (percentage of remaining),
   :fill (takes leftover after fixed + percentage).
   Returns an array of resolved sizes."
  [total constraints]
  (var fixed-sum 0)
  (var pct-sum 0)
  (var fill-count 0)
  (each c constraints
    (cond
      (= c :fill) (++ fill-count)
      (and (number? c) (> c 0) (<= c 1) (not (int? c))) (+= pct-sum c)
      (+= fixed-sum c)))
  (def after-fixed (max 0 (- total fixed-sum)))
  # Percentages are relative to space remaining after fixed allocations
  (var pct-used 0)
  (def pct-sizes @{})
  (for i 0 (length constraints)
    (def c (get constraints i))
    (when (and (number? c) (> c 0) (<= c 1) (not (int? c)))
      (def sz (math/floor (* c after-fixed)))
      (put pct-sizes i sz)
      (+= pct-used sz)))
  (def leftover (max 0 (- after-fixed pct-used)))
  (def fill-size (if (> fill-count 0)
                   (math/floor (/ leftover fill-count))
                   0))
  (def sizes @[])
  (var used 0)
  (for i 0 (length constraints)
    (def c (get constraints i))
    (def sz
      (cond
        (= c :fill)
        (if (= i (dec (length constraints)))
          (- total used)
          fill-size)
        (get pct-sizes i)
        (get pct-sizes i)
        (min c (- total used))))
    (array/push sizes (max 0 sz))
    (+= used (max 0 sz)))
  # Ensure we allocate the entire available space. Due to flooring when
  # computing percentage-based sizes we can end up with unassigned columns
  # or rows; give any leftover cells to the last segment.
  (def remaining (- total used))
  (when (> remaining 0)
    (def last-idx (dec (length sizes)))
    (when (>= last-idx 0)
      (put sizes last-idx (+ (get sizes last-idx) remaining))))
  sizes)

(defn vsplit
  "Split a rect vertically (top to bottom) according to constraints.
   Each constraint is an integer (fixed height) or :fill.
   Returns a tuple of rects."
  [area & constraints]
  (def sizes (resolve-constraints (area :height) constraints))
  (def result @[])
  (var y (area :y))
  (each h sizes
    (array/push result (rect (area :x) y (area :width) h))
    (+= y h))
  (tuple ;result))

(defn hsplit
  "Split a rect horizontally (left to right) according to constraints.
   Each constraint is an integer (fixed width) or :fill.
   Returns a tuple of rects."
  [area & constraints]
  (def sizes (resolve-constraints (area :width) constraints))
  (def result @[])
  (var x (area :x))
  (each w sizes
    (array/push result (rect x (area :y) w (area :height)))
    (+= x w))
  (tuple ;result))

(defn resolve-layout
  "Resolve a 2-level declarative layout into widget rect assignments.
   Layout is an array of row descriptors:
     {:widget :name :constraint <int|float|:fill|fn>}     — leaf row
     {:constraint <int|float|:fill|fn> :children [...]}   — horizontal group
   Returns @{:widget-name rect ...}."
  [layout area]
  (def result @{})
  (def v-constraints (map |(eval-constraint ($ :constraint)) layout))
  (def v-sizes (resolve-constraints (area :height) v-constraints))
  (var y (area :y))
  (for i 0 (length layout)
    (def entry (get layout i))
    (def h (get v-sizes i))
    (def row-rect (rect (area :x) y (area :width) h))
    (if (entry :widget)
      (put result (entry :widget) row-rect)
      (when (entry :children)
        (def children (entry :children))
        (def h-constraints (map |(eval-constraint ($ :constraint)) children))
        (def h-sizes (resolve-constraints (area :width) h-constraints))
        (var x (area :x))
        (for j 0 (length children)
          (def child (get children j))
          (def w (get h-sizes j))
          (when (child :widget)
            (put result (child :widget) (rect x y w h)))
          (+= x w))))
    (+= y h))
  result)
