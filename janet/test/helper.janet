# test/helper.janet — Minimal test framework.
#
# (import test/helper :prefix t/)
# (t/test "name" (fn [] (t/assert= 1 1)))
# (def pass (t/pass))
# (def fail (t/fail))

(var- pass-count 0)
(var- fail-count 0)

(defn pass [] pass-count)
(defn fail [] fail-count)

(defn assert=
  "Assert two values are equal. Returns true/false."
  [a b]
  (if (deep= a b)
    (do (++ pass-count) true)
    (do (++ fail-count)
        (eprintf "  FAIL: expected %q, got %q" b a)
        false)))

(defn assert-truthy
  "Assert value is truthy."
  [x]
  (if x
    (do (++ pass-count) true)
    (do (++ fail-count)
        (eprintf "  FAIL: expected truthy, got %q" x)
        false)))

(defn assert-falsy
  "Assert value is falsy."
  [x]
  (if (not x)
    (do (++ pass-count) true)
    (do (++ fail-count)
        (eprintf "  FAIL: expected falsy, got %q" x)
        false)))

(defn test
  "Run a named test."
  [name f]
  (def before-fail fail-count)
  (try
    (f)
    ([err]
      (++ fail-count)
      (eprintf "  ERROR in %s: %s" name (string err))))
  (if (= fail-count before-fail)
    (printf "  ✓ %s" name)
    (printf "  ✗ %s" name)))
