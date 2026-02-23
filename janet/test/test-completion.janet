# Tests for core/completion — trigger detection, filtering, state machine,
# navigation, and styled span invalidation.
(import core/buffers :as buffers)
(import core/commands :as commands)
(import core/completion :as completion)
(import widgets/editor_new :as ed)
(import tui)
(import test/helper :as t)

(print "── core/completion ──")

# ── Register some test commands ──

(commands/register "help" {:description "Show help" :function (fn [_] "")})
(commands/register "clear" {:description "Clear history" :function (fn [_] "")})
(commands/register "fork" {:description "Fork session" :function (fn [_] "")})
(commands/register "rollback" {:description "Rollback to message" :function (fn [_] "")})

# ── Trigger detection ──

(t/test "/ at start triggers command" (fn []
  (def result (completion/check-trigger "/" 1))
  (t/assert= (result :kind) :command)
  (t/assert= (result :start) 0)))

(t/test "/ after space triggers command" (fn []
  (def result (completion/check-trigger "hello /" 7))
  (t/assert= (result :kind) :command)
  (t/assert= (result :start) 6)))

(t/test "/ after newline triggers command" (fn []
  (def result (completion/check-trigger "hello\n/" 7))
  (t/assert= (result :kind) :command)
  (t/assert= (result :start) 6)))

(t/test "/ mid-word does not trigger" (fn []
  (def result (completion/check-trigger "hello/" 6))
  (t/assert-falsy result)))

(t/test "@ anywhere triggers file" (fn []
  (def result (completion/check-trigger "@" 1))
  (t/assert= (result :kind) :file)
  (t/assert= (result :start) 0)))

(t/test "@ after text triggers file" (fn []
  (def result (completion/check-trigger "check @" 7))
  (t/assert= (result :kind) :file)
  (t/assert= (result :start) 6)))

(t/test "no trigger on empty cursor" (fn []
  (def result (completion/check-trigger "" 0))
  (t/assert-falsy result)))

(t/test "no trigger for regular char" (fn []
  (def result (completion/check-trigger "hello" 5))
  (t/assert-falsy result)))

# ── State machine ──

(t/test "starts idle" (fn []
  (completion/dismiss)
  (t/assert-falsy (completion/active?))))

(t/test "activate sets active" (fn []
  (completion/activate :command 0)
  (t/assert-truthy (completion/active?))
  (completion/dismiss)))

(t/test "dismiss returns to idle" (fn []
  (completion/activate :command 0)
  (completion/dismiss)
  (t/assert-falsy (completion/active?))))

# ── Filtering ──

(t/test "filter commands with empty prefix" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/" 1))
  (t/assert-truthy (> count 0))
  (completion/dismiss)))

(t/test "filter commands with prefix" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/cl" 3))
  (t/assert= count 1)
  (def candidates (completion/get-candidates))
  (t/assert= ((first candidates) :label) "/clear")
  (completion/dismiss)))

(t/test "filter commands case insensitive" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/CL" 3))
  (t/assert= count 1)
  (completion/dismiss)))

(t/test "filter commands no match" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/zzz" 4))
  (t/assert= count 0)
  (completion/dismiss)))

(t/test "filter returns multiple commands for /" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/" 1))
  (t/assert-truthy (>= count 4))
  (completion/dismiss)))

# ── Navigation ──

(t/test "select-next wraps around" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/" 1))
  (t/assert= (completion/get-selected) 0)
  (completion/select-next)
  (t/assert= (completion/get-selected) 1)
  # Wrap around: go to last then next should be 0
  (for _ 0 (- count 1) (completion/select-next))
  (t/assert= (completion/get-selected) 0)
  (completion/dismiss)))

(t/test "select-prev wraps around" (fn []
  (completion/activate :command 0)
  (def count (completion/filter-candidates "/" 1))
  (t/assert= (completion/get-selected) 0)
  (completion/select-prev)
  (t/assert= (completion/get-selected) (- count 1))
  (completion/select-prev)
  (t/assert= (completion/get-selected) (- count 2))
  (completion/dismiss)))

# ── Accept ──

(t/test "accept returns insert text" (fn []
  (completion/activate :command 0)
  (completion/filter-candidates "/cl" 3)
  (def result (completion/accept 3))
  (t/assert-truthy result)
  (t/assert= (result :insert) "/clear ")
  (t/assert= (result :start) 0)
  (t/assert= (result :end) 3)
  (t/assert-falsy (completion/active?))))

(t/test "accept with no candidates returns nil" (fn []
  (completion/activate :command 0)
  (completion/filter-candidates "/zzz" 4)
  (def result (completion/accept 4))
  (t/assert-falsy result)
  (completion/dismiss)))

(t/test "accept when idle returns nil" (fn []
  (completion/dismiss)
  (def result (completion/accept 0))
  (t/assert-falsy result)))

# ── Popup rendering ──

(t/test "render-popup returns nil when idle" (fn []
  (completion/dismiss)
  (def area (tui/rect 0 0 80 24))
  (def result (completion/render-popup 20 5 area))
  (t/assert-falsy result)))

(t/test "render-popup returns data when active with candidates" (fn []
  (completion/activate :command 0)
  (completion/filter-candidates "/" 1)
  (def area (tui/rect 0 0 80 24))
  (def result (completion/render-popup 20 5 area))
  (t/assert-truthy result)
  (t/assert-truthy (> (length (result :cells)) 0))
  (t/assert-truthy (> (result :width) 0))
  (t/assert-truthy (> (result :height) 0))
  (completion/dismiss)))

(t/test "render-popup returns nil with no candidates" (fn []
  (completion/activate :command 0)
  (completion/filter-candidates "/zzz" 4)
  (def area (tui/rect 0 0 80 24))
  (def result (completion/render-popup 20 5 area))
  (t/assert-falsy result)
  (completion/dismiss)))

# ── Style ──

(t/test "default style is cyan bold" (fn []
  (def s (completion/get-style))
  (t/assert= (s :fg) :cyan)
  (t/assert= (s :bold) true)))

(t/test "set-style changes style" (fn []
  (def old (completion/get-style))
  (completion/set-style (tui/style :fg :magenta :bold true))
  (def s (completion/get-style))
  (t/assert= (s :fg) :magenta)
  (completion/set-style old)))

# ── Styled span invalidation (via editor_new) ──

(t/test "add-styled-span creates span" (fn []
  (def state (ed/new 80 5 "hello"))
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (t/assert= (length (state :styled-spans)) 1)
  (t/assert= ((first (state :styled-spans)) :start) 0)
  (t/assert= ((first (state :styled-spans)) :end) 5)))

(t/test "insert after span does not shift it" (fn []
  (def state (ed/new 80 5 "hello"))
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (ed/insert-text state "xx")
  (t/assert= ((first (state :styled-spans)) :start) 0)
  (t/assert= ((first (state :styled-spans)) :end) 5)))

(t/test "insert at start of buffer shifts span" (fn []
  (def state (ed/new 80 5 "hello"))
  (buffers/set-point (state :buf) 0)
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (ed/insert-char state "x")
  (t/assert= ((first (state :styled-spans)) :start) 1)
  (t/assert= ((first (state :styled-spans)) :end) 6)))

(t/test "delete within span shrinks it" (fn []
  (def state (ed/new 80 5 "hello"))
  (buffers/set-point (state :buf) 3)
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (ed/delete-back state)
  (t/assert= ((first (state :styled-spans)) :start) 0)
  (t/assert= ((first (state :styled-spans)) :end) 4)))

(t/test "delete after span does not affect it" (fn []
  (def state (ed/new 80 5 "hello world"))
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (ed/delete-back state)
  (t/assert= ((first (state :styled-spans)) :start) 0)
  (t/assert= ((first (state :styled-spans)) :end) 5)))

(t/test "set-text clears all spans" (fn []
  (def state (ed/new 80 5 "hello"))
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (ed/set-text state "new text")
  (t/assert= (length (state :styled-spans)) 0)))

(t/test "clear-styled-spans removes all" (fn []
  (def state (ed/new 80 5 "hello"))
  (ed/add-styled-span state 0 3 (tui/style :fg :cyan))
  (ed/add-styled-span state 3 5 (tui/style :fg :red))
  (t/assert= (length (state :styled-spans)) 2)
  (ed/clear-styled-spans state)
  (t/assert= (length (state :styled-spans)) 0)))

# ── Render with spans ──

(t/test "render returns spans" (fn []
  (def state (ed/new 80 5 "hello"))
  (ed/add-styled-span state 0 5 (tui/style :fg :cyan))
  (def r (ed/render state))
  (t/assert-truthy (r :spans))
  (t/assert= (length (r :spans)) 1)
  (def span (first (r :spans)))
  (t/assert= (span :row) 0)
  (t/assert= (span :col-start) 0)
  (t/assert= (span :col-end) 5)))

(t/test "render returns empty spans when none exist" (fn []
  (def state (ed/new 80 5 "hello"))
  (def r (ed/render state))
  (t/assert-truthy (r :spans))
  (t/assert= (length (r :spans)) 0)))

(def pass (t/pass))
(def fail (t/fail))
