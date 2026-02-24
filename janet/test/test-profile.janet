# Tests for core/profile
(import core/profile :as profile)
(import test/helper :as t)

(print "── core/profile ──")

(t/test "enable/disable toggle" (fn []
  (profile/disable)
  (t/assert-falsy (profile/enabled?))
  (profile/enable)
  (t/assert-truthy (profile/enabled?))
  (profile/disable)
  (t/assert-falsy (profile/enabled?))))

(t/test "begin/end records stats" (fn []
  (profile/reset)
  (profile/enable)
  (def id (profile/begin "test-op" "test"))
  (t/assert-truthy (not (nil? id)))
  (profile/end id)
  (def stats (profile/get-stats))
  (def s (get stats "test-op"))
  (t/assert-truthy (not (nil? s)))
  (t/assert= (s :count) 1)
  (t/assert-truthy (>= (s :total-us) 0))
  (t/assert-truthy (>= (s :max-us) 0))
  (profile/disable)))

(t/test "with-span returns function result and records stats" (fn []
  (profile/reset)
  (profile/enable)
  (def result (profile/with-span "span-test" "test" (fn [] 42)))
  (t/assert= result 42)
  (def stats (profile/get-stats))
  (def s (get stats "span-test"))
  (t/assert-truthy (not (nil? s)))
  (t/assert= (s :count) 1)
  (profile/disable)))

(t/test "with-span propagates errors" (fn []
  (profile/reset)
  (profile/enable)
  (var caught nil)
  (try
    (profile/with-span "err-span" "test" (fn [] (error "boom")))
    ([e] (set caught e)))
  (t/assert= caught "boom")
  (def stats (profile/get-stats))
  (def s (get stats "err-span"))
  (t/assert-truthy (not (nil? s)))
  (t/assert= (s :count) 1)
  (profile/disable)))

(t/test "disabled mode: begin returns nil, no stats recorded" (fn []
  (profile/reset)
  (profile/disable)
  (def id (profile/begin "nope" "test"))
  (t/assert-truthy (nil? id))
  (def stats (profile/get-stats))
  (t/assert-truthy (nil? (get stats "nope")))))

(t/test "disabled mode: with-span still calls function" (fn []
  (profile/reset)
  (profile/disable)
  (def result (profile/with-span "nope" "test" (fn [] 99)))
  (t/assert= result 99)
  (def stats (profile/get-stats))
  (t/assert-truthy (nil? (get stats "nope")))))

(t/test "reset clears everything" (fn []
  (profile/reset)
  (profile/enable)
  (profile/with-span "to-clear" "test" (fn [] nil))
  (t/assert-truthy (not (nil? (get (profile/get-stats) "to-clear"))))
  (profile/reset)
  (t/assert-truthy (empty? (profile/get-stats)))
  (profile/disable)))

(t/test "multiple spans accumulate stats" (fn []
  (profile/reset)
  (profile/enable)
  (profile/with-span "multi" "test" (fn [] nil))
  (profile/with-span "multi" "test" (fn [] nil))
  (profile/with-span "multi" "test" (fn [] nil))
  (def stats (profile/get-stats))
  (def s (get stats "multi"))
  (t/assert= (s :count) 3)
  (profile/disable)))

(t/test "format-stats returns a string" (fn []
  (profile/reset)
  (profile/enable)
  (profile/with-span "fmt-test" "test" (fn [] nil))
  (def result (profile/format-stats))
  (t/assert-truthy (string? result))
  (t/assert-truthy (string/find "fmt-test" result))
  (profile/disable)))

(t/test "format-stats when empty" (fn []
  (profile/reset)
  (profile/enable)
  (def result (profile/format-stats))
  (t/assert= result "No profiling data collected.")
  (profile/disable)))

(t/test "with-span-meta attaches metadata" (fn []
  (profile/reset)
  (profile/enable)
  (def result (profile/with-span-meta "meta-test" "test" {:coalesced 4} (fn [] :ok)))
  (t/assert= result :ok)
  (def stats (profile/get-stats))
  (t/assert= (get-in stats ["meta-test" :count]) 1)
  (profile/disable)))

(t/test "export-trace generates path with fallback timestamp" (fn []
  (profile/reset)
  (profile/enable)
  
  # Generate some profile data and export
  (profile/with-span "export-test" "test" (fn [] nil))
  (def path (profile/export-trace))
  
  # Verify the path uses either session name or timestamp format
  (t/assert-truthy (string/has-prefix? ".gent/profile-" path))
  (t/assert-truthy (string/has-suffix? ".json" path))
  
  # Clean up - remove the file if it was created
  (try (os/rm path) ([_]))
  (profile/disable)))

# Clean up
(profile/disable)
(profile/reset)

(def pass (t/pass))
(def fail (t/fail))
