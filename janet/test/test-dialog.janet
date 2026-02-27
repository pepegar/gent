# test/test-dialog.janet — Tests for core/dialog state machine and rendering.

(import test/helper :as t)
(import core/dialog :as dialog)
(import core/widget :as widget)
(import tui)

(print "\n── dialog ──")

# ── State machine ────────────────────────────────────────────

(t/test "initially idle" (fn []
                          (dialog/reset-state)
                          (t/assert-falsy (dialog/active?))))

(t/test "show activates dialog" (fn []
                                 (dialog/reset-state)
                                 (dialog/show {:type :select :title "Pick one"
                                               :options [{:label "A" :value "a"} {:label "B" :value "b"}]})
                                 (t/assert-truthy (dialog/active?))
                                 (t/assert= (dialog/get-type) :select)))

(t/test "show returns result-box" (fn []
                                   (dialog/reset-state)
                                   (def rb (dialog/show {:type :select :title "Pick" :options [{:label "X"}]}))
                                   (t/assert-truthy (table? rb))
                                   (t/assert= (rb :value) nil)
                                   (t/assert= (rb :cancelled) false)))

(t/test "dismiss sets cancelled" (fn []
                                  (dialog/reset-state)
                                  (def rb (dialog/show {:type :select :title "Q" :options [{:label "A"}]}))
                                  (dialog/dismiss)
                                  (t/assert-falsy (dialog/active?))
                                  (t/assert= (rb :cancelled) true)
                                  (t/assert= (rb :value) nil)))

(t/test "submit sets value for select" (fn []
                                        (dialog/reset-state)
                                        (def rb (dialog/show {:type :select :title "Q"
                                                              :options [{:label "A" :value "alpha"}
                                                                        {:label "B" :value "beta"}]}))
                                        (dialog/submit)
                                        (t/assert-falsy (dialog/active?))
                                        (t/assert= (rb :value) "alpha")
                                        (t/assert= (rb :cancelled) false)))

(t/test "submit confirm defaults to yes" (fn []
                                          (dialog/reset-state)
                                          (def rb (dialog/show {:type :confirm :title "Are you sure?"}))
                                          (dialog/submit)
                                          (t/assert= (rb :value) "yes")))

(t/test "submit confirm no after select-next" (fn []
                                               (dialog/reset-state)
                                               (def rb (dialog/show {:type :confirm :title "Sure?"}))
                                               (dialog/select-next)
                                               (dialog/submit)
                                               (t/assert= (rb :value) "no")))

(t/test "submit input returns typed text" (fn []
                                           (dialog/reset-state)
                                           (def rb (dialog/show {:type :input :title "Name?"}))
                                           (dialog/input-insert "h")
                                           (dialog/input-insert "i")
                                           (dialog/submit)
                                           (t/assert= (rb :value) "hi")))

(t/test "input default value" (fn []
                               (dialog/reset-state)
                               (def rb (dialog/show {:type :input :title "Name?" :default "world"}))
                               (t/assert= (dialog/get-input-text) "world")
                               (dialog/submit)
                               (t/assert= (rb :value) "world")))

# ── Navigation ───────────────────────────────────────────────

(t/test "select-next wraps around" (fn []
                                    (dialog/reset-state)
                                    (dialog/show {:type :select :title "Q"
                                                  :options [{:label "A"} {:label "B"} {:label "C"}]})
                                    (dialog/select-next)
                                    (dialog/select-next)
                                    (dialog/select-next)
                                    (def rb (dialog/show {:type :select :title "Q"
                                                          :options [{:label "A"} {:label "B"} {:label "C"}]}))
                                    (dialog/select-next)
                                    (dialog/select-next)
                                    (dialog/select-next)
                                    (dialog/submit)
                                    (t/assert= (rb :value) "A")))

(t/test "select-prev wraps around" (fn []
                                    (dialog/reset-state)
                                    (def rb (dialog/show {:type :select :title "Q"
                                                          :options [{:label "A" :value "a"}
                                                                    {:label "B" :value "b"}
                                                                    {:label "C" :value "c"}]}))
                                    (dialog/select-prev)
                                    (dialog/submit)
                                    (t/assert= (rb :value) "c")))

(t/test "select-idx jumps and submits" (fn []
                                        (dialog/reset-state)
                                        (def rb (dialog/show {:type :select :title "Q"
                                                              :options [{:label "A" :value "a"}
                                                                        {:label "B" :value "b"}
                                                                        {:label "C" :value "c"}]}))
                                        (dialog/select-idx 2)
                                        (t/assert-falsy (dialog/active?))
                                        (t/assert= (rb :value) "c")))

(t/test "select-idx out of range does nothing" (fn []
                                                (dialog/reset-state)
                                                (def rb (dialog/show {:type :select :title "Q"
                                                                      :options [{:label "A" :value "a"}]}))
                                                (dialog/select-idx 5)
                                                (t/assert-truthy (dialog/active?))
                                                (t/assert= (rb :value) nil)))

# ── Option normalization ─────────────────────────────────────

(t/test "string options normalized to label+value" (fn []
                                                    (dialog/reset-state)
                                                    (def rb (dialog/show {:type :select :title "Q"
                                                                          :options ["foo" "bar"]}))
                                                    (dialog/submit)
                                                    (t/assert= (rb :value) "foo")))

(t/test "option without value uses label" (fn []
                                           (dialog/reset-state)
                                           (def rb (dialog/show {:type :select :title "Q"
                                                                 :options [{:label "xyz"}]}))
                                           (dialog/submit)
                                           (t/assert= (rb :value) "xyz")))

# ── Input editing ────────────────────────────────────────────

(t/test "input-insert appends text" (fn []
                                     (dialog/reset-state)
                                     (dialog/show {:type :input :title "Q"})
                                     (dialog/input-insert "a")
                                     (dialog/input-insert "b")
                                     (dialog/input-insert "c")
                                     (t/assert= (dialog/get-input-text) "abc")))

(t/test "input-delete-back removes char" (fn []
                                          (dialog/reset-state)
                                          (dialog/show {:type :input :title "Q"})
                                          (dialog/input-insert "a")
                                          (dialog/input-insert "b")
                                          (dialog/input-delete-back)
                                          (t/assert= (dialog/get-input-text) "a")))

(t/test "input-delete-back at start does nothing" (fn []
                                                   (dialog/reset-state)
                                                   (dialog/show {:type :input :title "Q"})
                                                   (dialog/input-delete-back)
                                                   (t/assert= (dialog/get-input-text) "")))

(t/test "input cursor movement and insert" (fn []
                                            (dialog/reset-state)
                                            (dialog/show {:type :input :title "Q"})
                                            (dialog/input-insert "a")
                                            (dialog/input-insert "c")
                                            (dialog/input-move-left)
                                            (dialog/input-insert "b")
                                            (t/assert= (dialog/get-input-text) "abc")))

(t/test "input-clear resets text" (fn []
                                   (dialog/reset-state)
                                   (dialog/show {:type :input :title "Q"})
                                   (dialog/input-insert "hello")
                                   (dialog/input-clear)
                                   (t/assert= (dialog/get-input-text) "")))

# ── Render overlay ───────────────────────────────────────────

(t/test "render-overlay returns nil when idle" (fn []
                                                (dialog/reset-state)
                                                (def area (tui/rect 0 0 80 24))
                                                (t/assert= (dialog/render-overlay area) nil)))

(t/test "render-overlay returns cell structure" (fn []
                                                 (dialog/reset-state)
                                                 (dialog/show {:type :select :title "Pick"
                                                               :options [{:label "A"} {:label "B"}]})
                                                 (def area (tui/rect 0 0 80 24))
                                                 (def result (dialog/render-overlay area))
                                                 (t/assert-truthy (not (nil? result)))
                                                 (t/assert-truthy (> (length (result :cells)) 0))
                                                 (t/assert-truthy (> (result :width) 0))
                                                 (t/assert-truthy (> (result :height) 0))))

(t/test "render-overlay is centered" (fn []
                                      (dialog/reset-state)
                                      (dialog/show {:type :select :title "Q"
                                                    :options [{:label "A"}]})
                                      (def area (tui/rect 0 0 80 24))
                                      (def result (dialog/render-overlay area))
                                      (def expected-x (math/floor (/ (- 80 (result :width)) 2)))
                                      (def expected-y (math/floor (/ (- 24 (result :height)) 2)))
                                      (t/assert= (result :x) expected-x)
                                      (t/assert= (result :y) expected-y)))

(t/test "render-overlay has correct height for select" (fn []
                                                        (dialog/reset-state)
                                                        (dialog/show {:type :select :title "Q"
                                                                      :options [{:label "A"} {:label "B"} {:label "C"}]})
                                                        (def area (tui/rect 0 0 80 24))
                                                        (def result (dialog/render-overlay area))
  # height = content_rows(3) + 5 = 8
                                                        (t/assert= (result :height) 8)))

(t/test "render-overlay has correct height for input" (fn []
                                                       (dialog/reset-state)
                                                       (dialog/show {:type :input :title "Q"})
                                                       (def area (tui/rect 0 0 80 24))
                                                       (def result (dialog/render-overlay area))
  # height = content_rows(1) + 5 = 6
                                                       (t/assert= (result :height) 6)))

(t/test "render-overlay corners are rounded" (fn []
                                              (dialog/reset-state)
                                              (dialog/show {:type :select :title "Q" :options [{:label "A"}]})
                                              (def area (tui/rect 0 0 80 24))
                                              (def result (dialog/render-overlay area))
                                              (def cells (result :cells))
                                              (def tl (get cells 0))
                                              (t/assert= (tl :ch) "╭")
                                              (def last-cell (get cells (- (length cells) 1)))
                                              (t/assert= (last-cell :ch) "╯")))

# ── Dismiss is idempotent ────────────────────────────────────

(t/test "dismiss when idle is no-op" (fn []
                                      (dialog/reset-state)
                                      (dialog/dismiss)
                                      (t/assert-falsy (dialog/active?))))

(t/test "submit when idle is no-op" (fn []
                                     (dialog/reset-state)
                                     (dialog/submit)
                                     (t/assert-falsy (dialog/active?))))

# ── Async tool integration ───────────────────────────────────

(t/test "result-box poll pattern" (fn []
                                   (dialog/reset-state)
                                   (def rb (dialog/show {:type :select :title "Q"
                                                         :options [{:label "A" :value "alpha"}]}))
  # Before interaction — not ready
                                   (t/assert= (rb :value) nil)
                                   (t/assert= (rb :cancelled) false)
  # Submit
                                   (dialog/submit)
                                   (t/assert= (rb :value) "alpha")))

(t/test "result-box poll pattern cancel" (fn []
                                          (dialog/reset-state)
                                          (def rb (dialog/show {:type :select :title "Q"
                                                                :options [{:label "A"}]}))
                                          (dialog/dismiss)
                                          (t/assert= (rb :cancelled) true)
                                          (t/assert= (rb :value) nil)))

# ── Export pass/fail counts ──────────────────────────────────

(def pass (t/pass))
(def fail (t/fail))
