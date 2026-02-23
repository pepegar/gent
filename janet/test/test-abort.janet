# Tests for core/abort
(import core/abort :as abort)
(import test/helper :as t)

(print "── core/abort ──")

(t/test "starts not aborted" (fn []
  (abort/clear-abort!)
  (t/assert-falsy (abort/aborted?))))

(t/test "abort! sets flag" (fn []
  (abort/clear-abort!)
  (abort/abort!)
  (t/assert-truthy (abort/aborted?))))

(t/test "clear-abort! clears flag" (fn []
  (abort/abort!)
  (abort/clear-abort!)
  (t/assert-falsy (abort/aborted?))))

(t/test "multiple abort! is idempotent" (fn []
  (abort/clear-abort!)
  (abort/abort!)
  (abort/abort!)
  (t/assert-truthy (abort/aborted?))
  (abort/clear-abort!)
  (t/assert-falsy (abort/aborted?))))

(def pass (t/pass))
(def fail (t/fail))
