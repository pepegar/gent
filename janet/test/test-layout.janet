# Tests for tui/layout
(use tui/rect)
(use tui/layout)
(import test/helper :as t)

(print "── tui/layout ──")

(t/test "vsplit with fixed sizes" (fn []
                                   (def area (rect 0 0 80 24))
                                   (def [a b c] (vsplit area 5 10 9))
                                   (t/assert= (a :y) 0)
                                   (t/assert= (a :height) 5)
                                   (t/assert= (b :y) 5)
                                   (t/assert= (b :height) 10)
                                   (t/assert= (c :y) 15)
                                   (t/assert= (c :height) 9)))

(t/test "vsplit with :fill" (fn []
                             (def area (rect 0 0 80 24))
                             (def [top mid bot] (vsplit area 3 :fill 1))
                             (t/assert= (top :height) 3)
                             (t/assert= (mid :height) 20)
                             (t/assert= (bot :height) 1)
  # All widths should match parent
                             (t/assert= (top :width) 80)
                             (t/assert= (mid :width) 80)))

(t/test "vsplit multiple fills" (fn []
                                 (def area (rect 0 0 80 24))
                                 (def [a b] (vsplit area :fill :fill))
                                 (t/assert= (a :height) 12)
                                 (t/assert= (b :height) 12)))

(t/test "hsplit with fixed sizes" (fn []
                                   (def area (rect 0 0 80 24))
                                   (def [a b] (hsplit area 20 60))
                                   (t/assert= (a :x) 0)
                                   (t/assert= (a :width) 20)
                                   (t/assert= (b :x) 20)
                                   (t/assert= (b :width) 60)))

(t/test "hsplit with :fill" (fn []
                             (def area (rect 0 0 80 24))
                             (def [sidebar main] (hsplit area 20 :fill))
                             (t/assert= (sidebar :width) 20)
                             (t/assert= (main :width) 60)
  # Heights match parent
                             (t/assert= (sidebar :height) 24)
                             (t/assert= (main :height) 24)))

(t/test "default gent layout" (fn []
                               (def area (rect 0 0 80 24))
                               (def [chat sep editor] (vsplit area :fill 1 1))
                               (t/assert= (chat :height) 22)
                               (t/assert= (sep :height) 1)
                               (t/assert= (editor :height) 1)
                               (t/assert= (sep :y) 22)
                               (t/assert= (editor :y) 23)))

(def pass (t/pass))
(def fail (t/fail))
