# test/test-inspect.janet — Tests for the state inspection module.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/inspect :as inspect)
(import core/widget :as widget)
(import core/registers :as reg)
(import widgets/chat :as chat)
(import tui)
(import test/helper :as t)

(print "── core/inspect ──")

# ── Helpers ────────────────────────────────────────────────────

(defn- setup []
  (chat/reset-state)
  (reg/clear)
  (each name (widget/list-widgets) (widget/unregister name))
  (def w (chat/create))
  (widget/register w)
  (widget/set-layout-fn (fn [a] @{:chat (tui/rect 0 0 80 22)}))
  (widget/do-layout (tui/rect 0 0 80 24))
  w)

# ── Chat state ────────────────────────────────────────────────

(t/test "chat-state reports idle mode" (fn []
  (setup)
  (def s (inspect/chat-state))
  (t/assert= (s :mode) :idle)
  (t/assert= (s :scrollback-count) 0)
  (t/assert= (s :scroll-offset) 0)
  (t/assert-falsy (s :active))))

(t/test "chat-state reflects scrollback after output" (fn []
  (setup)
  (chat/output "line 1")
  (chat/output "line 2")
  (def s (inspect/chat-state))
  (t/assert= (s :scrollback-count) 2)))

# ── Scrollback text ──────────────────────────────────────────

(t/test "scrollback-text extracts plain text from simple lines" (fn []
  (setup)
  (chat/output "hello")
  (chat/output "world")
  (def texts (inspect/scrollback-text))
  (t/assert= (length texts) 2)
  (t/assert= (get texts 0) "hello")
  (t/assert= (get texts 1) "world")))

(t/test "scrollback-text flattens spans" (fn []
  (setup)
  (chat/output-user "test message")
  (def texts (inspect/scrollback-text))
  (t/assert= (length texts) 1)
  (t/assert-truthy (string/find "you" (get texts 0)))
  (t/assert-truthy (string/find "test message" (get texts 0)))))

(t/test "scrollback-text handles error spans" (fn []
  (setup)
  (chat/output-error "something broke")
  (def texts (inspect/scrollback-text))
  (t/assert= (length texts) 1)
  (t/assert-truthy (string/find "error" (get texts 0)))
  (t/assert-truthy (string/find "something broke" (get texts 0)))))

(t/test "scrollback-text handles mixed content" (fn []
  (setup)
  (chat/output "plain line")
  (chat/output-user "user input")
  (chat/output-error "bad thing")
  (chat/output-info "info")
  (def texts (inspect/scrollback-text))
  # output-user inserts a blank line before the label (spacing)
  (t/assert= (get texts 0) "plain line")
  (def non-empty (filter |(not= "" $) texts))
  (t/assert= (length non-empty) 4)
  (t/assert-truthy (some |(string/find "user input" $) non-empty))
  (t/assert-truthy (some |(string/find "bad thing" $) non-empty))
  (t/assert-truthy (some |(= "info" $) non-empty))))

# ── Widgets state ────────────────────────────────────────────

(t/test "widgets-state lists registered widgets" (fn []
  (setup)
  (def s (inspect/widgets-state))
  (t/assert-truthy (get s :chat))
  (t/assert-truthy (get-in s [:chat :rect]))))

# ── Registers ────────────────────────────────────────────────

(t/test "registers-state reflects stored values" (fn []
  (setup)
  (reg/set :test-key "test-value")
  (def s (inspect/registers-state))
  (t/assert= (get s :test-key) "test-value")
  (reg/clear :test-key)))

# ── Full state ───────────────────────────────────────────────

(t/test "full-state returns all sections" (fn []
  (setup)
  (def s (inspect/full-state))
  (t/assert-truthy (s :chat))
  (t/assert-truthy (s :widgets))
  (t/assert-truthy (s :conversation))
  (t/assert-truthy (has-key? s :tools))
  (t/assert-truthy (has-key? s :registers))
  (t/assert-truthy (has-key? s :hooks))))

(def pass (t/pass))
(def fail (t/fail))
