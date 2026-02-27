# Tests for tui/rect
(use tui/rect)
(import test/helper :as t)

(print "── tui/rect ──")

(t/test "rect creates struct with correct fields" (fn []
                                                   (def r (rect 5 10 80 24))
                                                   (t/assert= (r :x) 5)
                                                   (t/assert= (r :y) 10)
                                                   (t/assert= (r :width) 80)
                                                   (t/assert= (r :height) 24)))

(t/test "rect-right and rect-bottom" (fn []
                                      (def r (rect 5 10 80 24))
                                      (t/assert= (rect-right r) 85)
                                      (t/assert= (rect-bottom r) 34)))

(t/test "rect-area" (fn []
                     (t/assert= (rect-area (rect 0 0 10 5)) 50)
                     (t/assert= (rect-area rect-zero) 0)))

(t/test "rect-empty?" (fn []
                       (t/assert-truthy (rect-empty? rect-zero))
                       (t/assert-truthy (rect-empty? (rect 0 0 0 5)))
                       (t/assert-truthy (rect-empty? (rect 0 0 5 0)))
                       (t/assert-falsy (rect-empty? (rect 0 0 1 1)))))

(t/test "rect-intersection" (fn []
                             (def a (rect 0 0 10 10))
                             (def b (rect 5 5 10 10))
                             (def c (rect-intersection a b))
                             (t/assert= (c :x) 5)
                             (t/assert= (c :y) 5)
                             (t/assert= (c :width) 5)
                             (t/assert= (c :height) 5)))

(t/test "rect-intersection no overlap" (fn []
                                        (def a (rect 0 0 5 5))
                                        (def b (rect 10 10 5 5))
                                        (t/assert-truthy (rect-empty? (rect-intersection a b)))))

(t/test "rect-contains?" (fn []
                          (def r (rect 5 5 10 10))
                          (t/assert-truthy (rect-contains? r 5 5))
                          (t/assert-truthy (rect-contains? r 14 14))
                          (t/assert-falsy (rect-contains? r 15 15))
                          (t/assert-falsy (rect-contains? r 4 5))))

(t/test "rect-inner" (fn []
                      (def r (rect 0 0 20 10))
                      (def inner (rect-inner r {:left 2 :right 2 :top 1 :bottom 1}))
                      (t/assert= (inner :x) 2)
                      (t/assert= (inner :y) 1)
                      (t/assert= (inner :width) 16)
                      (t/assert= (inner :height) 8)))

(def pass (t/pass))
(def fail (t/fail))
