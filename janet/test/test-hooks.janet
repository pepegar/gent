# Tests for core/hooks
(import core/hooks :as hooks)
(import test/helper :as t)

(print "── core/hooks ──")

(t/test "add and run hook" (fn []
                            (hooks/clear :test-hook)
                            (var called false)
                            (hooks/add :test-hook (fn [] (set called true)))
                            (hooks/run :test-hook)
                            (t/assert-truthy called)))

(t/test "hook receives arguments" (fn []
                                   (hooks/clear :test-args)
                                   (var got-args nil)
                                   (hooks/add :test-args (fn [a b] (set got-args [a b])))
                                   (hooks/run :test-args "hello" 42)
                                   (t/assert= got-args ["hello" 42])))

(t/test "multiple hooks run in order" (fn []
                                       (hooks/clear :test-order)
                                       (var log @[])
                                       (hooks/add :test-order (fn [] (array/push log 1)))
                                       (hooks/add :test-order (fn [] (array/push log 2)))
                                       (hooks/run :test-order)
                                       (t/assert= log @[1 2])))

(t/test "hook error doesn't stop other hooks" (fn []
                                               (hooks/clear :test-error)
                                               (var called false)
                                               (hooks/add :test-error (fn [] (error "boom")))
                                               (hooks/add :test-error (fn [] (set called true)))
                                               (hooks/run :test-error)
                                               (t/assert-truthy called)))

(t/test "run returns last non-nil value" (fn []
                                          (hooks/clear :test-ret)
                                          (hooks/add :test-ret (fn [] nil))
                                          (hooks/add :test-ret (fn [] :found))
                                          (t/assert= (hooks/run :test-ret) :found)))

(t/test "remove hook function" (fn []
                                (hooks/clear :test-remove)
                                (var count 0)
                                (def f (fn [] (++ count)))
                                (hooks/add :test-remove f)
                                (hooks/run :test-remove)
                                (t/assert= count 1)
                                (hooks/remove :test-remove f)
                                (hooks/run :test-remove)
                                (t/assert= count 1)))

(t/test "list-hooks" (fn []
                      (hooks/clear :test-list)
                      (hooks/add :test-list (fn [] nil))
                      (def hl (hooks/list-hooks))
                      (t/assert-truthy (find |(= $ :test-list) hl))))

(def pass (t/pass))
(def fail (t/fail))
