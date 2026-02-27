# Tests for core/buffers point tracking
(import core/buffers :as buffers)
(import test/helper :as t)

(print "── core/buffers (point) ──")

# ── Point defaults ──

(t/test "new buffer has point 0" (fn []
                                  (def buf (buffers/create "*test-default*"))
                                  (t/assert= (buffers/get-point buf) 0)
                                  (buffers/close "*test-default*")))

# ── set-point / get-point ──

(t/test "set-point and get-point" (fn []
                                   (def buf (buffers/create "*test-sp*" "hello"))
                                   (buffers/set-point buf 3)
                                   (t/assert= (buffers/get-point buf) 3)
                                   (buffers/close "*test-sp*")))

(t/test "set-point clamps below zero" (fn []
                                       (def buf (buffers/create "*test-clamp-lo*" "abc"))
                                       (buffers/set-point buf -5)
                                       (t/assert= (buffers/get-point buf) 0)
                                       (buffers/close "*test-clamp-lo*")))

(t/test "set-point clamps above length" (fn []
                                         (def buf (buffers/create "*test-clamp-hi*" "abc"))
                                         (buffers/set-point buf 100)
                                         (t/assert= (buffers/get-point buf) 3)
                                         (buffers/close "*test-clamp-hi*")))

(t/test "point-at-end? true when at end" (fn []
                                          (def buf (buffers/create "*test-end*" "hi"))
                                          (buffers/set-point buf 2)
                                          (t/assert-truthy (buffers/point-at-end? buf))
                                          (buffers/close "*test-end*")))

(t/test "point-at-end? false when not at end" (fn []
                                               (def buf (buffers/create "*test-notend*" "hi"))
                                               (buffers/set-point buf 0)
                                               (t/assert-falsy (buffers/point-at-end? buf))
                                               (buffers/close "*test-notend*")))

# ── Insert + point ──

(t/test "insert before point shifts point right" (fn []
                                                  (def buf (buffers/create "*test-ins-before*" "abcde"))
                                                  (buffers/set-point buf 3)
                                                  (buffers/insert buf 1 "XX")
                                                  (t/assert= (buffers/string-content buf) "aXXbcde")
                                                  (t/assert= (buffers/get-point buf) 5)
                                                  (buffers/close "*test-ins-before*")))

(t/test "insert at point shifts point right" (fn []
                                              (def buf (buffers/create "*test-ins-at*" "abcde"))
                                              (buffers/set-point buf 3)
                                              (buffers/insert buf 3 "XX")
                                              (t/assert= (buffers/string-content buf) "abcXXde")
                                              (t/assert= (buffers/get-point buf) 5)
                                              (buffers/close "*test-ins-at*")))

(t/test "insert after point does not move point" (fn []
                                                  (def buf (buffers/create "*test-ins-after*" "abcde"))
                                                  (buffers/set-point buf 2)
                                                  (buffers/insert buf 4 "XX")
                                                  (t/assert= (buffers/string-content buf) "abcdXXe")
                                                  (t/assert= (buffers/get-point buf) 2)
                                                  (buffers/close "*test-ins-after*")))

# ── Delete + point ──

(t/test "delete before point shifts point left" (fn []
                                                 (def buf (buffers/create "*test-del-before*" "abcde"))
                                                 (buffers/set-point buf 4)
                                                 (buffers/delete buf 1 3)
                                                 (t/assert= (buffers/string-content buf) "ade")
                                                 (t/assert= (buffers/get-point buf) 2)
                                                 (buffers/close "*test-del-before*")))

(t/test "delete spanning point collapses to start" (fn []
                                                    (def buf (buffers/create "*test-del-span*" "abcde"))
                                                    (buffers/set-point buf 3)
                                                    (buffers/delete buf 1 4)
                                                    (t/assert= (buffers/string-content buf) "ae")
                                                    (t/assert= (buffers/get-point buf) 1)
                                                    (buffers/close "*test-del-span*")))

(t/test "delete after point does not move point" (fn []
                                                  (def buf (buffers/create "*test-del-after*" "abcde"))
                                                  (buffers/set-point buf 1)
                                                  (buffers/delete buf 3 5)
                                                  (t/assert= (buffers/string-content buf) "abc")
                                                  (t/assert= (buffers/get-point buf) 1)
                                                  (buffers/close "*test-del-after*")))

# ── Replace + point ──

(t/test "replace before point adjusts by delta" (fn []
                                                 (def buf (buffers/create "*test-rep-before*" "aXXbc"))
                                                 (buffers/set-point buf 4)
                                                 (buffers/replace buf "XX" "YYYY")
                                                 (t/assert= (buffers/string-content buf) "aYYYYbc")
                                                 (t/assert= (buffers/get-point buf) 6)
                                                 (buffers/close "*test-rep-before*")))

(t/test "replace spanning point moves to end of replacement" (fn []
                                                              (def buf (buffers/create "*test-rep-span*" "abcde"))
                                                              (buffers/set-point buf 3)
                                                              (buffers/replace buf "bcd" "XY")
                                                              (t/assert= (buffers/string-content buf) "aXYe")
                                                              (t/assert= (buffers/get-point buf) 3)
                                                              (buffers/close "*test-rep-span*")))

(t/test "replace after point does not move point" (fn []
                                                   (def buf (buffers/create "*test-rep-after*" "abcde"))
                                                   (buffers/set-point buf 1)
                                                   (buffers/replace buf "cde" "XX")
                                                   (t/assert= (buffers/string-content buf) "abXX")
                                                   (t/assert= (buffers/get-point buf) 1)
                                                   (buffers/close "*test-rep-after*")))

# ── Replace-all + point ──

(t/test "replace-all cumulative shift before point" (fn []
                                                     (def buf (buffers/create "*test-ra-cum*" "aXbXcXd"))
                                                     (buffers/set-point buf 6)
                                                     (buffers/replace-all buf "X" "YY")
                                                     (t/assert= (buffers/string-content buf) "aYYbYYcYYd")
                                                     (t/assert= (buffers/get-point buf) 9)
                                                     (buffers/close "*test-ra-cum*")))

(t/test "replace-all point inside match" (fn []
                                          (def buf (buffers/create "*test-ra-inside*" "aXXbXXc"))
                                          (buffers/set-point buf 2)
                                          (buffers/replace-all buf "XX" "Y")
                                          (t/assert= (buffers/string-content buf) "aYbYc")
                                          (t/assert= (buffers/get-point buf) 2)
                                          (buffers/close "*test-ra-inside*")))

(t/test "replace-all point after all matches" (fn []
                                               (def buf (buffers/create "*test-ra-end*" "aXbXc"))
                                               (buffers/set-point buf 5)
                                               (buffers/replace-all buf "X" "YYY")
                                               (t/assert= (buffers/string-content buf) "aYYYbYYYc")
                                               (t/assert= (buffers/get-point buf) 9)
                                               (buffers/close "*test-ra-end*")))

(def pass (t/pass))
(def fail (t/fail))
