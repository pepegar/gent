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

(def pass (t/pass))
(def fail (t/fail))
