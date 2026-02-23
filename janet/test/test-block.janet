# Tests for tui/block
(use tui/rect)
(use tui/style)
(use tui/buffer)
(use tui/block)
(import test/helper :as t)

(print "── tui/block ──")

(t/test "block-inner with no borders" (fn []
  (def b (block :borders :none))
  (def area (rect 0 0 20 10))
  (def inner (block-inner b area))
  (t/assert= (inner :x) 0)
  (t/assert= (inner :y) 0)
  (t/assert= (inner :width) 20)
  (t/assert= (inner :height) 10)))

(t/test "block-inner with all borders" (fn []
  (def b (block :borders :all))
  (def area (rect 0 0 20 10))
  (def inner (block-inner b area))
  (t/assert= (inner :x) 1)
  (t/assert= (inner :y) 1)
  (t/assert= (inner :width) 18)
  (t/assert= (inner :height) 8)))

(t/test "block-inner with title" (fn []
  (def b (block :title "Hello" :borders :all))
  (def area (rect 0 0 20 10))
  (def inner (block-inner b area))
  # Title takes top row (same as top border)
  (t/assert= (inner :y) 1)
  (t/assert= (inner :height) 8)))

(t/test "block-inner with padding" (fn []
  (def b (block :borders :all :padding (padding 2 2 1 1)))
  (def area (rect 0 0 20 10))
  (def inner (block-inner b area))
  (t/assert= (inner :x) 3)  # border + padding
  (t/assert= (inner :y) 2)  # border + padding
  (t/assert= (inner :width) 14)
  (t/assert= (inner :height) 6)))

(t/test "block renders borders" (fn []
  (def b (block :borders :all :border-type :rounded))
  (def area (rect 0 0 5 3))
  (def buf (buffer area))
  ((b :render) b area buf)
  # Top-left corner should be ╭
  (t/assert= ((buffer-get buf 0 0) :ch) "╭")
  # Top-right corner should be ╮
  (t/assert= ((buffer-get buf 4 0) :ch) "╮")
  # Bottom-left should be ╰
  (t/assert= ((buffer-get buf 0 2) :ch) "╰")))

(t/test "block renders title" (fn []
  (def b (block :title "Hi" :borders :all))
  (def area (rect 0 0 10 3))
  (def buf (buffer area))
  ((b :render) b area buf)
  # Title should appear after top-left border
  # Title is " Hi " so position 1 should be space, 2 should be H
  (t/assert= ((buffer-get buf 1 0) :ch) " ")
  (t/assert= ((buffer-get buf 2 0) :ch) "H")
  (t/assert= ((buffer-get buf 3 0) :ch) "i")))

(def pass (t/pass))
(def fail (t/fail))
