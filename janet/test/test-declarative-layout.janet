# Tests for declarative 2-level layout (tui/layout resolve-layout)
(use tui/rect)
(use tui/layout)
(import test/helper :as t)

(print "── declarative layout ──")

(t/test "single widget fills entire area" (fn []
  (def layout @[{:widget :chat :constraint :fill}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:chat :x]) 0)
  (t/assert= (get-in result [:chat :y]) 0)
  (t/assert= (get-in result [:chat :width]) 80)
  (t/assert= (get-in result [:chat :height]) 24)))

(t/test "three vertical rows: fill + fixed + fixed" (fn []
  (def layout @[{:widget :chat :constraint :fill}
                {:widget :sep :constraint 1}
                {:widget :ed :constraint 5}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:chat :height]) 18)
  (t/assert= (get-in result [:chat :y]) 0)
  (t/assert= (get-in result [:sep :height]) 1)
  (t/assert= (get-in result [:sep :y]) 18)
  (t/assert= (get-in result [:ed :height]) 5)
  (t/assert= (get-in result [:ed :y]) 19)
  (t/assert= (get-in result [:chat :width]) 80)
  (t/assert= (get-in result [:sep :width]) 80)
  (t/assert= (get-in result [:ed :width]) 80)))

(t/test "horizontal children within a row" (fn []
  (def layout @[{:constraint :fill
                 :children [{:widget :chat :constraint :fill}
                            {:widget :sidebar :constraint 20}]}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:chat :width]) 60)
  (t/assert= (get-in result [:chat :x]) 0)
  (t/assert= (get-in result [:sidebar :width]) 20)
  (t/assert= (get-in result [:sidebar :x]) 60)
  (t/assert= (get-in result [:chat :height]) 24)
  (t/assert= (get-in result [:sidebar :height]) 24)))

(t/test "mixed: horizontal group + leaf rows" (fn []
  (def layout @[{:constraint :fill
                 :children [{:widget :chat :constraint :fill}
                            {:widget :sidebar :constraint 30}]}
                {:widget :sep :constraint 1}
                {:widget :ed :constraint 5}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:chat :height]) 18)
  (t/assert= (get-in result [:chat :width]) 50)
  (t/assert= (get-in result [:sidebar :height]) 18)
  (t/assert= (get-in result [:sidebar :width]) 30)
  (t/assert= (get-in result [:sep :y]) 18)
  (t/assert= (get-in result [:ed :y]) 19)))

(t/test "function constraints are evaluated" (fn []
  (def layout @[{:widget :a :constraint |(+ 3 2)}
                {:widget :b :constraint :fill}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:a :height]) 5)
  (t/assert= (get-in result [:b :height]) 19)))

(t/test "percentage constraints" (fn []
  (def layout @[{:widget :top :constraint 0.75}
                {:widget :bot :constraint 0.25}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:top :height]) 18)
  (t/assert= (get-in result [:bot :height]) 6)))

(t/test "percentage + fixed + fill" (fn []
  (def layout @[{:widget :chat :constraint 0.8}
                {:widget :sep :constraint 1}
                {:widget :ed :constraint :fill}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  # After fixed (1), remaining = 23. 80% of 23 = 18.
  (t/assert= (get-in result [:chat :height]) 18)
  (t/assert= (get-in result [:sep :height]) 1)
  # Fill gets leftover: 24 - 18 - 1 = 5
  (t/assert= (get-in result [:ed :height]) 5)))

(t/test "horizontal percentage constraints" (fn []
  (def layout @[{:constraint :fill
                 :children [{:widget :main :constraint 0.7}
                            {:widget :side :constraint 0.3}]}])
  (def result (resolve-layout layout (rect 0 0 100 24)))
  (t/assert= (get-in result [:main :width]) 70)
  (t/assert= (get-in result [:side :width]) 30)))

(t/test "default gent layout matches expected" (fn []
  (def ed-height 1)
  (def layout @[{:constraint :fill
                 :children [{:widget :chat :constraint :fill}]}
                {:widget :separator :constraint 1}
                {:widget :editor :constraint |(identity ed-height)}])
  (def result (resolve-layout layout (rect 0 0 80 24)))
  (t/assert= (get-in result [:chat :height]) 22)
  (t/assert= (get-in result [:chat :width]) 80)
  (t/assert= (get-in result [:separator :height]) 1)
  (t/assert= (get-in result [:separator :y]) 22)
  (t/assert= (get-in result [:editor :height]) 1)
  (t/assert= (get-in result [:editor :y]) 23)))

(t/test "non-origin area offset preserved" (fn []
  (def layout @[{:widget :a :constraint 5}
                {:widget :b :constraint :fill}])
  (def result (resolve-layout layout (rect 10 20 60 30)))
  (t/assert= (get-in result [:a :x]) 10)
  (t/assert= (get-in result [:a :y]) 20)
  (t/assert= (get-in result [:a :width]) 60)
  (t/assert= (get-in result [:a :height]) 5)
  (t/assert= (get-in result [:b :x]) 10)
  (t/assert= (get-in result [:b :y]) 25)
  (t/assert= (get-in result [:b :height]) 25)))

(def pass (t/pass))
(def fail (t/fail))
