# test/test-fuzzy.janet — Tests for core/fuzzy module.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/fuzzy :as fuzzy)
(import test/helper :as t)

(print "── core/fuzzy ──")

(t/test "score returns nil for empty target" (fn []
                                              (t/assert= (fuzzy/score "" "abc") nil)))

(t/test "score returns inf score for empty query" (fn []
                                                   (def result (fuzzy/score "hello" ""))
                                                   (t/assert-truthy result)
                                                   (t/assert= (result :score) math/inf)))

(t/test "score matches exact prefix" (fn []
                                      (def result (fuzzy/score "hello" "hel"))
                                      (t/assert-truthy result)
                                      (t/assert-truthy (< (result :score) math/inf))))

(t/test "score matches subsequence" (fn []
                                     (def result (fuzzy/score "src/main.rs" "main"))
                                     (t/assert-truthy result)))

(t/test "score returns nil for no match" (fn []
                                          (t/assert= (fuzzy/score "hello" "xyz") nil)))

(t/test "score is case insensitive" (fn []
                                     (def result (fuzzy/score "README.md" "read"))
                                     (t/assert-truthy result)))

(t/test "score prefers word boundaries" (fn []
                                         (def boundary (fuzzy/score "foo-bar" "fb"))
                                         (def no-boundary (fuzzy/score "fooxxb" "fb"))
                                         (t/assert-truthy boundary)
                                         (t/assert-truthy no-boundary)
                                         (t/assert-truthy (< (boundary :score) (no-boundary :score)))))

(t/test "filter-sort returns all items for empty query" (fn []
                                                         (def items @["a" "b" "c"])
                                                         (def results (fuzzy/filter-sort items ""))
                                                         (t/assert= (length results) 3)
                                                         (t/assert= ((get results 0) :item) "a")))

(t/test "filter-sort filters and sorts by score" (fn []
                                                  (def items @["src/main.rs" "README.md" "Cargo.toml" "src/lib.rs"])
                                                  (def results (fuzzy/filter-sort items "main"))
                                                  (t/assert= (length results) 1)
                                                  (t/assert= ((get results 0) :item) "src/main.rs")))

(t/test "filter-sort returns empty for no matches" (fn []
                                                    (def items @["a.txt" "b.txt"])
                                                    (def results (fuzzy/filter-sort items "zzz"))
                                                    (t/assert= (length results) 0)))

(def pass (t/pass))
(def fail (t/fail))