# tui/layout.janet — Split rects into sub-regions.
#
# Provides vsplit (vertical stacking) and hsplit (horizontal stacking)
# with a simple constraint system: fixed sizes and :fill for remaining space.
#
# Usage:
#   (def [header body footer] (vsplit area 3 :fill 1))
#   (def [sidebar main]       (hsplit area 20 :fill))

(use ./rect)

(defn- resolve-constraints
  "Resolve a list of constraints against a total size.
   Constraints: integer (fixed size), :fill (takes remaining space).
   Returns an array of resolved sizes."
  [total constraints]
  (var fixed-sum 0)
  (var fill-count 0)
  (each c constraints
    (if (= c :fill)
      (++ fill-count)
      (+= fixed-sum c)))
  (def remaining (max 0 (- total fixed-sum)))
  (def fill-size (if (> fill-count 0)
                   (math/floor (/ remaining fill-count))
                   0))
  (def sizes @[])
  (var used 0)
  (for i 0 (length constraints)
    (def c (get constraints i))
    (def sz
      (if (= c :fill)
        (if (= i (dec (length constraints)))
          # Last fill gets any leftover pixels to avoid gaps
          (- total used)
          fill-size)
        (min c (- total used))))
    (array/push sizes (max 0 sz))
    (+= used (max 0 sz)))
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
