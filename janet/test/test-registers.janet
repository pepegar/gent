# Tests for core/registers
(import core/registers :as reg)
(import test/helper :as t)

(print "── core/registers ──")

(t/test "set and get" (fn []
                       (reg/set :test-key "value")
                       (t/assert= (reg/get :test-key) "value")))

(t/test "get with default" (fn []
                            (t/assert= (reg/get :nonexistent "default") "default")))

(t/test "get missing returns nil" (fn []
                                   (t/assert= (reg/get :also-nonexistent) nil)))

(t/test "set overwrites" (fn []
                          (reg/set :overwrite 1)
                          (reg/set :overwrite 2)
                          (t/assert= (reg/get :overwrite) 2)))

(t/test "list returns names" (fn []
                              (reg/set :list-a 1)
                              (reg/set :list-b 2)
                              (def names (reg/list))
                              (t/assert-truthy (find |(= $ :list-a) names))
                              (t/assert-truthy (find |(= $ :list-b) names))))

(t/test "clear specific" (fn []
                          (reg/set :clearme "data")
                          (reg/clear :clearme)
                          (t/assert= (reg/get :clearme) nil)))

(t/test "set returns value" (fn []
                             (t/assert= (reg/set :ret-test 42) 42)))

(t/test "push creates array on first use" (fn []
                                            (reg/clear :push-new)
                                            (reg/push :push-new "a")
                                            (t/assert= (reg/get :push-new) @["a"])))

(t/test "push appends to existing array" (fn []
                                           (reg/clear :push-append)
                                           (reg/push :push-append "x")
                                           (reg/push :push-append "y")
                                           (reg/push :push-append "z")
                                           (t/assert= (reg/get :push-append) @["x" "y" "z"])))

(t/test "push returns the pushed value" (fn []
                                          (reg/clear :push-ret)
                                          (t/assert= (reg/push :push-ret 99) 99)))

(t/test "drain returns all items and clears" (fn []
                                               (reg/clear :drain-test)
                                               (reg/push :drain-test "m1")
                                               (reg/push :drain-test "m2")
                                               (def result (reg/drain :drain-test))
                                               (t/assert= result @["m1" "m2"])
                                               (t/assert= (reg/get :drain-test) @[])))

(t/test "drain on missing register returns empty array" (fn []
                                                          (reg/clear :drain-missing)
                                                          (t/assert= (reg/drain :drain-missing) @[])))

(t/test "drain is atomic: subsequent drain is empty" (fn []
                                                       (reg/clear :drain-atomic)
                                                       (reg/push :drain-atomic "once")
                                                       (reg/drain :drain-atomic)
                                                       (t/assert= (reg/drain :drain-atomic) @[])))

(def pass (t/pass))
(def fail (t/fail))
