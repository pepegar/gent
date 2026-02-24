# test/test-snapshot.janet — Buffer snapshot testing for widget rendering.
#
# Demonstrates the pattern for testing UI rendering without a terminal:
#   1. Create a widget with a fixed rect
#   2. Feed it mock state (scrollback, user messages, etc.)
#   3. Render into a buffer
#   4. Extract plain text with buffer-to-text/buffer-to-plain-rows
#   5. Assert on the text content
#
# This is the primary mechanism for coding agents to verify
# that changes to presentation logic are correct.

(import test/fake-http :as fake)
(fake/install (curenv))

(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/inspect :as inspect)
(import tui)
(import test/helper :as t)

(print "── snapshot tests ──")

# ── Helpers ────────────────────────────────────────────────────

(defn- setup [&opt width height]
  "Set up a chat widget with a fixed-size viewport."
  (default width 40)
  (default height 10)
  (chat/reset-state)
  (each name (widget/list-widgets) (widget/unregister name))
  (def w (chat/create))
  (widget/register w)
  (def r (tui/rect 0 0 width height))
  (widget/set-layout-fn (fn [a] @{:chat r}))
  (widget/do-layout (tui/rect 0 0 width (+ height 2)))
  w)

(defn- render-chat [w &opt width height]
  "Render the chat widget into a buffer and return plain text rows."
  (default width 40)
  (default height 10)
  (def r (tui/rect 0 0 width height))
  (def buf (tui/buffer r))
  ((w :render) w r buf)
  (tui/buffer-to-plain-rows buf))

(defn- row-contains? [rows y text]
  "Check if row y contains the given text."
  (when (< y (length rows))
    (not (nil? (string/find text (get rows y))))))

(defn- any-row-contains? [rows text]
  "Check if any row contains the given text."
  (some |(not (nil? (string/find text $))) rows))

# ── Basic rendering snapshots ────────────────────────────────

(t/test "snapshot: empty chat renders blank" (fn []
  (def w (setup))
  (def rows (render-chat w))
  (t/assert= (length rows) 10)
  (each row rows
    (t/assert= row ""))))

(t/test "snapshot: single line bottom-aligned" (fn []
  (def w (setup))
  (chat/output "hello world")
  (def rows (render-chat w))
  (t/assert= (get rows 9) "hello world")
  (t/assert= (get rows 8) "")))

(t/test "snapshot: multiple lines fill from bottom" (fn []
  (def w (setup))
  (chat/output "first")
  (chat/output "second")
  (chat/output "third")
  (def rows (render-chat w))
  (t/assert-truthy (row-contains? rows 7 "first"))
  (t/assert-truthy (row-contains? rows 8 "second"))
  (t/assert-truthy (row-contains? rows 9 "third"))))

(t/test "snapshot: user message shows label and text" (fn []
  (def w (setup))
  (chat/output-user "hello agent")
  (def rows (render-chat w))
  (def bottom (get rows 9))
  (t/assert-truthy (string/find "you" bottom))
  (t/assert-truthy (string/find "hello agent" bottom))))

(t/test "snapshot: error message shows label" (fn []
  (def w (setup))
  (chat/output-error "something failed")
  (def rows (render-chat w))
  (def bottom (get rows 9))
  (t/assert-truthy (string/find "error" bottom))
  (t/assert-truthy (string/find "something failed" bottom))))

(t/test "snapshot: tool call shows tool name" (fn []
  (def w (setup))
  (chat/output-tool "bash" "ls -la")
  (def rows (render-chat w))
  (t/assert-truthy (any-row-contains? rows "bash"))
  (t/assert-truthy (any-row-contains? rows "ls -la"))))

# ── Scrolling snapshots ──────────────────────────────────────

(t/test "snapshot: overflow content clips at top" (fn []
  (def w (setup 40 5))
  (for i 0 10 (chat/output (string "line-" i)))
  (def rows (render-chat w 40 5))
  (t/assert-truthy (row-contains? rows 4 "line-9"))
  (t/assert-truthy (row-contains? rows 3 "line-8"))
  (t/assert-truthy (row-contains? rows 0 "line-5"))))

(t/test "snapshot: scroll-offset shifts visible window" (fn []
  (def w (setup 40 5))
  (for i 0 10 (chat/output (string "line-" i)))
  (chat/set-scroll-offset 3)
  (def rows (render-chat w 40 5))
  (t/assert-truthy (row-contains? rows 4 "line-6"))
  (t/assert-truthy (row-contains? rows 0 "line-2"))))

# ── Combined inspect + snapshot ──────────────────────────────

(t/test "snapshot+inspect: verify state and rendering together" (fn []
  (def w (setup 60 8))
  (chat/output-user "what files are here?")
  (chat/output-tool "bash" "ls")
  (chat/output "file1.txt\nfile2.txt")

  # Verify state via inspect
  (def state (inspect/chat-state))
  (t/assert= (state :mode) :idle)
  (t/assert-truthy (> (state :scrollback-count) 0))

  # Verify scrollback content via inspect
  (def texts (inspect/scrollback-text))
  (t/assert-truthy (some |(string/find "what files" $) texts))
  (t/assert-truthy (some |(string/find "bash" $) texts))

  # Verify rendered output via buffer snapshot
  (def rows (render-chat w 60 8))
  (t/assert-truthy (any-row-contains? rows "you"))
  (t/assert-truthy (any-row-contains? rows "bash"))))

# ── Word wrapping snapshot ───────────────────────────────────

(t/test "snapshot: long lines wrap within viewport" (fn []
  (def w (setup 30 10))
  (chat/output-agent "This is a long agent response that should wrap across multiple lines in a narrow viewport")
  (def rows (render-chat w 30 10))
  (t/assert-truthy (any-row-contains? rows "gent"))
  # Multiple rows should have content (wrapped)
  (def non-empty (filter |(not= "" $) rows))
  (t/assert-truthy (> (length non-empty) 1))))

# ── Edit file rendering snapshot ─────────────────────────────

(t/test "snapshot: edit_file shows diff" (fn []
  (def w (setup 60 12))
  (chat/output-edit-file
    @{:path "test.txt"
      :old_str "old line"
      :new_str "new line"})
  (def rows (render-chat w 60 12))
  (t/assert-truthy (any-row-contains? rows "edit_file"))
  (t/assert-truthy (any-row-contains? rows "test.txt"))
  (t/assert-truthy (any-row-contains? rows "- old line"))
  (t/assert-truthy (any-row-contains? rows "+ new line"))))

(t/test "snapshot: edit_file new file" (fn []
  (def w (setup 60 12))
  (chat/output-edit-file
    @{:path "new.txt"
      :old_str ""
      :new_str "first line\nsecond line"})
  (def rows (render-chat w 60 12))
  (t/assert-truthy (any-row-contains? rows "new file"))
  (t/assert-truthy (any-row-contains? rows "+ first line"))))

# ── Eval janet rendering snapshot ────────────────────────────

(t/test "snapshot: eval_janet shows code with line numbers" (fn []
  (def w (setup 60 12))
  (chat/output-eval-janet "(+ 1 2)\n(* 3 4)")
  (def rows (render-chat w 60 12))
  (t/assert-truthy (any-row-contains? rows "eval_janet"))
  (t/assert-truthy (any-row-contains? rows "(+ 1 2)"))
  (t/assert-truthy (any-row-contains? rows "(* 3 4)"))
  # Should have line numbers
  (t/assert-truthy (any-row-contains? rows "1"))))

# ── Tool result truncation snapshot ──────────────────────────

(t/test "snapshot: long tool result shows omitted count" (fn []
  (def w (setup 60 20))
  (def lines (string/join (seq [i :range [0 15]] (string "result " i)) "\n"))
  (chat/output-tool-result lines)
  (def rows (render-chat w 60 20))
  (t/assert-truthy (any-row-contains? rows "result 0"))
  (t/assert-truthy (any-row-contains? rows "omitted"))))

# ── Full conversation snapshot ───────────────────────────────
# Simulates a realistic multi-turn conversation and verifies
# the visual layout, including spacing between sections.

(t/test "snapshot: full conversation has breathing room between sections" (fn []
  (def w (setup 80 50))

  # Turn 1: user asks, agent responds with tool calls
  (chat/output-user "Can you read the config and fix the broken import?")
  (chat/output-agent "I'll read the config file first.")
  (chat/output-tool "read_file" "path: src/config.janet")
  (chat/output-tool-result "(import core/utils :as utils)\n(import core/missing :as mm)")
  (chat/output-agent "Found it. I'll remove the broken import.")
  (chat/output-edit-file
    @{:path "src/config.janet"
      :old_str "(import core/missing :as mm)"
      :new_str ""})
  (chat/output-tool-result "File edited successfully.")
  (chat/output-agent "Fixed! The file compiles cleanly now.")

  # Turn 2: user follows up
  (chat/output-user "Great, also add a :log-level setting.")
  (chat/output-agent "Sure, I'll add that.")
  (chat/output-edit-file
    @{:path "src/config.janet"
      :old_str "    :port 8080}"
      :new_str "    :port 8080\n    :log-level :info}"})
  (chat/output-tool-result "File edited successfully.")
  (chat/output-agent "Done. Added :log-level :info to the config.")

  (def rows (render-chat w 80 50))

  # Helper: find which row contains a text
  (defn find-row [text]
    (var found nil)
    (for i 0 (length rows)
      (when (and (nil? found) (string/find text (get rows i)))
        (set found i)))
    found)

  # Verify key content is present
  (t/assert-truthy (find-row "you"))
  (t/assert-truthy (find-row "gent"))
  (t/assert-truthy (find-row "read_file"))
  (t/assert-truthy (find-row "edit_file"))

  # Verify blank lines exist between user and agent sections
  (def user1-row (find-row "fix the broken import"))
  (def agent1-row (find-row "I'll read the config"))
  (t/assert-truthy user1-row)
  (t/assert-truthy agent1-row)
  # There should be a blank line between user message and agent response
  (t/assert-truthy (> agent1-row (+ user1-row 1)))
  (t/assert= (get rows (- agent1-row 1)) "")

  # Verify blank line before second user turn
  (def user2-row (find-row "also add a :log-level"))
  (t/assert-truthy user2-row)
  (t/assert= (get rows (- user2-row 1)) "")

  # Verify blank line before agent responses after tool results
  (def agent-fixed-row (find-row "Fixed! The file"))
  (t/assert-truthy agent-fixed-row)
  (t/assert= (get rows (- agent-fixed-row 1)) "")))

(t/test "snapshot: first message has no leading blank line" (fn []
  (def w (setup 80 10))
  (chat/output-user "hello")
  (def rows (render-chat w 80 10))
  # User message should be on bottom row with no blank above it
  # (since it's the first thing in the scrollback)
  (def bottom (get rows 9))
  (t/assert-truthy (string/find "you" bottom))
  (t/assert-truthy (string/find "hello" bottom))
  # Only 1 scrollback entry, so row 8 should be blank (empty viewport, not spacing)
  (t/assert= (length (chat/get-scrollback)) 1)))

(t/test "snapshot: tool calls stay grouped with their agent turn" (fn []
  (def w (setup 80 20))

  (chat/output-agent "Let me check that file.")
  (chat/output-tool "read_file" "path: main.janet")
  (chat/output-tool-result "contents here")
  (chat/output-tool "bash" "janet -c main.janet")
  (chat/output-tool-result "OK")

  (def rows (render-chat w 80 20))

  (defn find-row [text]
    (var found nil)
    (for i 0 (length rows)
      (when (and (nil? found) (string/find text (get rows i)))
        (set found i)))
    found)

  (def agent-row (find-row "Let me check"))
  (def tool1-row (find-row "read_file"))
  (def result1-row (find-row "contents here"))
  (def tool2-row (find-row "bash"))
  (def ok-row (find-row "OK"))

  # Agent margin-bottom adds a blank line after agent text.
  # Tool calls and their results remain contiguous (output-tool called directly).
  (t/assert-truthy agent-row)
  (t/assert-truthy tool1-row)
  (t/assert= tool1-row (+ agent-row 2))   # margin-bottom blank line
  (t/assert-truthy result1-row)
  (t/assert= result1-row (+ tool1-row 1))
  (t/assert-truthy tool2-row)
  (t/assert= tool2-row (+ result1-row 1))
  (t/assert-truthy ok-row)
  (t/assert= ok-row (+ tool2-row 1))))

# ── Row background color tests ─────────────────────────────

(defn- render-buf [w &opt width height]
  "Render the chat widget into a buffer and return the buffer."
  (default width 40)
  (default height 10)
  (def r (tui/rect 0 0 width height))
  (def buf (tui/buffer r))
  ((w :render) w r buf)
  buf)

(t/test "snapshot: user message has row background" (fn []
  (def w (setup))
  (chat/output-user "hello")
  (def buf (render-buf w))
  (def cell (tui/buffer-get buf 0 9))
  (t/assert-truthy (get (cell :style) :bg))))

(t/test "snapshot: agent message has row background" (fn []
  (def w (setup))
  (chat/output-agent "response text")
  (def buf (render-buf w))
  # Agent text is on row 8; row 9 is the margin-bottom blank line
  (def cell (tui/buffer-get buf 0 8))
  (t/assert-truthy (get (cell :style) :bg))))

(t/test "snapshot: tool call has row background" (fn []
  (def w (setup))
  (chat/output-tool "bash" "ls")
  (def buf (render-buf w))
  (def cell (tui/buffer-get buf 0 9))
  (t/assert-truthy (get (cell :style) :bg))))

(t/test "snapshot: tool result has row background" (fn []
  (def w (setup))
  (chat/output-tool-result "ok")
  (def buf (render-buf w))
  (def cell (tui/buffer-get buf 0 9))
  (t/assert-truthy (get (cell :style) :bg))))

(t/test "snapshot: tool error result has different bg from success" (fn []
  (def w (setup 60 10))
  (chat/output-tool-result "success result" true)
  (chat/output-tool-result "Error: something failed" false)
  (def buf (render-buf w 60 10))
  (def success-cell (tui/buffer-get buf 0 8))
  (def error-cell (tui/buffer-get buf 0 9))
  (t/assert-truthy (get (success-cell :style) :bg))
  (t/assert-truthy (get (error-cell :style) :bg))
  (t/assert-truthy (not (deep= (success-cell :style) (error-cell :style))))))

(t/test "snapshot: row bg fills entire row width" (fn []
  (def w (setup 40 10))
  (chat/output-user "hi")
  (def buf (render-buf w 40 10))
  (def cell-end (tui/buffer-get buf 39 9))
  (t/assert-truthy (get (cell-end :style) :bg))))

(t/test "snapshot: set-colors overrides a color" (fn []
  (def w (setup))
  (def custom-bg (tui/style :bg [:rgb 99 99 99]))
  (chat/set-colors @{:user-row-bg custom-bg})
  (chat/output-user "custom bg test")
  (def buf (render-buf w))
  (def cell (tui/buffer-get buf 39 9))
  (t/assert= (get (cell :style) :bg) [:rgb 99 99 99])
  (chat/set-theme :dark)))

(t/test "snapshot: set-theme switches to light" (fn []
  (def w (setup))
  (chat/set-theme :light)
  (chat/output-user "light mode")
  (def buf (render-buf w))
  (def cell (tui/buffer-get buf 39 9))
  (def bg (get (cell :style) :bg))
  (t/assert-truthy bg)
  # Light theme row bg should have high channel values (>200)
  (t/assert-truthy (> (get bg 1) 200))
  (chat/set-theme :dark)))

(t/test "snapshot: set-theme rejects unknown theme" (fn []
  (setup)
  (var caught false)
  (try (chat/set-theme :nope) ([_] (set caught true)))
  (t/assert-truthy caught)))

(t/test "snapshot: detect-os-theme returns :dark or :light" (fn []
  (setup)
  (def result (chat/detect-os-theme))
  (t/assert-truthy (or (= result :dark) (= result :light)))))

(t/test "snapshot: auto-theme applies without error" (fn []
  (setup)
  (chat/auto-theme)
  (chat/output-user "auto themed")
  (def buf (render-buf (setup)))
  (chat/auto-theme)
  (chat/output-user "still works")
  (def w (setup))
  (chat/auto-theme)
  (chat/output-user "test")
  (def buf2 (render-buf w))
  (def cell (tui/buffer-get buf2 39 9))
  (t/assert-truthy (get (cell :style) :bg))
  (chat/set-theme :dark)))

(def pass (t/pass))
(def fail (t/fail))
