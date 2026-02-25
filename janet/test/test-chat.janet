# test/test-chat.janet — Chat widget unit tests.
#
# Tests scrollback, scroll handling, and buffer rendering.
# Does not test the streaming/API pipeline (see test-chat-integration).

# ── Setup: install mocks before importing anything ─────────────

(import test/fake-http :as fake)
(fake/install (curenv))

(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/conversation :as conv)
(import tui)
(import test/helper :as t)

(print "── widgets/chat (unit) ──")

# ── Helpers ────────────────────────────────────────────────────

(defn- setup []
  "Reset chat and widget state for each test."
  (chat/reset-state)
  (each name (widget/list-widgets) (widget/unregister name))
  (def w (chat/create))
  (widget/register w)
  (widget/set-layout-fn (fn [a] @{:chat (tui/rect 0 0 80 22)}))
  (widget/do-layout (tui/rect 0 0 80 24))
  w)

(defn- read-buffer-row
  "Extract the text content of a buffer row (strip trailing spaces)."
  [buf y width]
  (def chars @[])
  (for x 0 width
    (array/push chars ((tui/buffer-get buf x y) :ch)))
  (string/trimr (string ;chars)))

# ── Scrollback tests ───────────────────────────────────────────

(t/test "output pushes to scrollback" (fn []
  (setup)
  (chat/output "hello")
  (t/assert= (length (chat/get-scrollback)) 1)
  (t/assert= ((first (chat/get-scrollback)) :text) "hello")))

(t/test "output-info pushes styled line" (fn []
  (setup)
  (chat/output-info "info text")
  (def line (first (chat/get-scrollback)))
  (t/assert= (line :text) "info text")
  (t/assert-truthy (line :style))))

(t/test "output-user pushes spans" (fn []
  (setup)
  (chat/output-user "hi there")
  (def line (first (chat/get-scrollback)))
  (t/assert-truthy (line :spans))
  # First span is the label, second is the text
  (t/assert= (length (line :spans)) 2)
  (t/assert-truthy (string/find "user:" ((first (line :spans)) :text)))
  (t/assert-truthy (string/find "hi there" ((last (line :spans)) :text)))))

(t/test "output-error pushes error spans" (fn []
  (setup)
  (chat/output-error "something broke")
  (def line (first (chat/get-scrollback)))
  (t/assert-truthy (line :spans))
  (t/assert-truthy (string/find "err:" ((first (line :spans)) :text)))))

(t/test "output-agent word-wraps long lines" (fn []
  (setup)
  # 80-col chat area, 8 chars indent, so ~72 chars per wrapped line
  (def long-text (string/repeat "word " 30))  # 150 chars
  (chat/output-agent long-text)
  (def sb (chat/get-scrollback))
  (t/assert-truthy (> (length sb) 1))))

(t/test "multiple outputs accumulate" (fn []
  (setup)
  (for i 0 10
    (chat/output (string "line " i)))
  (t/assert= (length (chat/get-scrollback)) 10)))

(t/test "reset-state clears scrollback" (fn []
  (setup)
  (chat/output "hello")
  (chat/output "world")
  (chat/reset-state)
  (t/assert= (length (chat/get-scrollback)) 0)
  (t/assert= (chat/get-scroll-offset) 0)
  (t/assert= (chat/get-mode) :idle)))

# ── Scroll tests ───────────────────────────────────────────────

(t/test "scroll-offset starts at 0" (fn []
  (setup)
  (t/assert= (chat/get-scroll-offset) 0)))

(t/test "scroll-line-up increments offset" (fn []
  (def w (setup))
  # Add enough lines to scroll
  (for i 0 30 (chat/output (string "line " i)))
  ((w :handle) w {:type :scroll-line-up})
  (t/assert= (chat/get-scroll-offset) 1)))

(t/test "scroll-line-down decrements offset" (fn []
  (def w (setup))
  (for i 0 30 (chat/output (string "line " i)))
  (chat/set-scroll-offset 5)
  ((w :handle) w {:type :scroll-line-down})
  (t/assert= (chat/get-scroll-offset) 4)))

(t/test "scroll-line-down clamps at 0" (fn []
  (def w (setup))
  (for i 0 30 (chat/output (string "line " i)))
  (chat/set-scroll-offset 0)
  ((w :handle) w {:type :scroll-line-down})
  (t/assert= (chat/get-scroll-offset) 0)))

(t/test "scroll-line-up clamps at max" (fn []
  (def w (setup))
  # 5 lines in a 22-row area → max-offset = max(0, 5-22) = 0
  (for i 0 5 (chat/output (string "line " i)))
  ((w :handle) w {:type :scroll-line-up})
  (t/assert= (chat/get-scroll-offset) 0)))

(t/test "scroll-up pages by height" (fn []
  (def w (setup))
  (for i 0 50 (chat/output (string "line " i)))
  ((w :handle) w {:type :scroll-up})
  # Page size = height - 2 = 20
  (t/assert= (chat/get-scroll-offset) 20)))

(t/test "scroll-down pages back" (fn []
  (def w (setup))
  (for i 0 50 (chat/output (string "line " i)))
  (chat/set-scroll-offset 20)
  ((w :handle) w {:type :scroll-down})
  (t/assert= (chat/get-scroll-offset) 0)))

(t/test "scroll-up clamps at max offset" (fn []
  (def w (setup))
  # 30 lines, 22-row area → max-offset = max(0, 30-22) = 8
  (for i 0 30 (chat/output (string "line " i)))
  # Page-up: page-size=20, but max-offset is 8, so clamped
  ((w :handle) w {:type :scroll-up})
  (t/assert= (chat/get-scroll-offset) 8)))

(t/test "set-scroll-offset works" (fn []
  (setup)
  (chat/set-scroll-offset 42)
  (t/assert= (chat/get-scroll-offset) 42)))

(t/test "new content while scrolled up keeps view stable" (fn []
  (def w (setup))
  (for i 0 30 (chat/output (string "line " i)))
  # Scroll up
  (chat/set-scroll-offset 5)
  # Add new content at the bottom
  (chat/output "new line A")
  (chat/output "new line B")
  # Offset should have increased by 2 to keep view stable
  (t/assert= (chat/get-scroll-offset) 7)))

(t/test "new content at bottom (offset 0) stays pinned" (fn []
  (setup)
  (chat/output "line 1")
  (t/assert= (chat/get-scroll-offset) 0)
  (chat/output "line 2")
  (t/assert= (chat/get-scroll-offset) 0)
  (chat/output "line 3")
  (t/assert= (chat/get-scroll-offset) 0)))

# ── Rendering tests ────────────────────────────────────────────

(t/test "render empty scrollback into buffer" (fn []
  (def w (setup))
  (def rect (tui/rect 0 0 80 22))
  (def buf (tui/buffer rect))
  ((w :render) w rect buf)
  # All cells should be spaces
  (t/assert= ((tui/buffer-get buf 0 0) :ch) " ")
  (t/assert= ((tui/buffer-get buf 79 21) :ch) " ")))

(t/test "render scrollback text appears in buffer" (fn []
  (def w (setup))
  (chat/output "hello world")
  (def rect (tui/rect 0 0 80 22))
  (def buf (tui/buffer rect))
  ((w :render) w rect buf)
  # "hello world" should be at the bottom row (pinned to bottom)
  (def row-text (read-buffer-row buf 21 80))
  (t/assert-truthy (string/find "hello world" row-text))))

(t/test "render multiple lines fill from bottom" (fn []
  (def w (setup))
  (chat/output "first")
  (chat/output "second")
  (chat/output "third")
  (def rect (tui/rect 0 0 80 22))
  (def buf (tui/buffer rect))
  ((w :render) w rect buf)
  # Last 3 rows should have content
  (def row19 (read-buffer-row buf 19 80))
  (def row20 (read-buffer-row buf 20 80))
  (def row21 (read-buffer-row buf 21 80))
  (t/assert-truthy (string/find "first" row19))
  (t/assert-truthy (string/find "second" row20))
  (t/assert-truthy (string/find "third" row21))))

(t/test "scroll-offset changes rendered window" (fn []
  (def w (setup))
  # Add 25 lines (more than the 22-row viewport)
  (for i 0 25 (chat/output (string "line-" i)))
  # Render pinned to bottom (offset=0): should show lines 3-24
  (def rect (tui/rect 0 0 80 22))
  (def buf1 (tui/buffer rect))
  ((w :render) w rect buf1)
  (def bottom-row1 (read-buffer-row buf1 21 80))
  (t/assert-truthy (string/find "line-24" bottom-row1))
  # Scroll up 3 lines: should show lines 0-21
  (chat/set-scroll-offset 3)
  (def buf2 (tui/buffer rect))
  ((w :render) w rect buf2)
  (def bottom-row2 (read-buffer-row buf2 21 80))
  (t/assert-truthy (string/find "line-21" bottom-row2))
  # Top row should now show line-0
  (def top-row2 (read-buffer-row buf2 0 80))
  (t/assert-truthy (string/find "line-0" top-row2))))

(t/test "render spans (user message) into buffer" (fn []
  (def w (setup))
  (chat/output-user "hello from user")
  (def rect (tui/rect 0 0 80 22))
  (def buf (tui/buffer rect))
  ((w :render) w rect buf)
  # The bottom row should contain "you" label and user text
  (def row-text (read-buffer-row buf 21 80))
  (t/assert-truthy (string/find "user:" row-text))
  (t/assert-truthy (string/find "hello from user" row-text))))

# ── Tool rendering tests ──────────────────────────────────────

(t/test "output-tool pushes tool label" (fn []
  (setup)
  (chat/output-tool "bash" "ls -la")
  (def line (first (chat/get-scrollback)))
  (t/assert-truthy (line :spans))
  (t/assert-truthy (string/find "bash" ((first (line :spans)) :text)))))

(t/test "output-tool-result truncates long output" (fn []
  (setup)
  (def long-output (string/join (seq [i :range [0 20]] (string "result line " i)) "\n"))
  (chat/output-tool-result long-output)
  (def sb (chat/get-scrollback))
  # Default max is 10 lines + 1 "omitted" line = 11
  (t/assert-truthy (<= (length sb) 12))))

# ── Mode tests ─────────────────────────────────────────────────

(t/test "starts in idle mode" (fn []
  (setup)
  (t/assert= (chat/get-mode) :idle)))

(t/test "active? is false when idle" (fn []
  (setup)
  (t/assert-falsy (chat/active?))))

(t/test "conversation clear hook clears scrollback" (fn []
  (setup)
  # Add some content to scrollback
  (chat/output-user "hello")
  (chat/output-agent "hi there")
  (def scrollback-before (length (chat/get-scrollback)))
  (t/assert-truthy (> scrollback-before 0))
  
  # Clear the conversation (this should trigger the hook)
  (conv/clear)
  
  # Verify scrollback is cleared
  (def scrollback-after (length (chat/get-scrollback)))
  (t/assert= 0 scrollback-after)))

(def pass (t/pass))
(def fail (t/fail))
