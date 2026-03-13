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
  "Set up a chat widget with a fixed-size viewport.
   Width and height refer to the content area; the actual buffer is +2 for the border."
  (default width 40)
  (default height 10)
  (chat/reset-state)
  (each name (widget/list-widgets) (widget/unregister name))
  (def w (chat/create))
  (widget/register w)
  (def bw (+ width 2))
  (def bh (+ height 2))
  (def r (tui/rect 0 0 bw bh))
  (widget/set-layout-fn (fn [a] @{:chat r}))
  (widget/do-layout (tui/rect 0 0 bw (+ bh 2)))
  w)

(defn- render-chat [w &opt width height]
  "Render the chat widget into a buffer and return plain text rows for the content area only.
   Reads cells directly from the inner area (offset by 1,1 for the border)."
  (default width 40)
  (default height 10)
  (def bw (+ width 2))
  (def bh (+ height 2))
  (def r (tui/rect 0 0 bw bh))
  (def buf (tui/buffer r))
  ((w :render) w r buf)
  (def content-rows @[])
  (for row 0 height
    (def chars @[])
    (for col 0 width
      (def cell (tui/buffer-get buf (+ col 1) (+ row 1)))
      (array/push chars (cell :ch)))
    (array/push content-rows (string/trimr (string ;chars))))
  content-rows)

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
                                                       (t/assert-truthy (string/find "user:" bottom))
                                                       (t/assert-truthy (string/find "hello agent" bottom))))

(t/test "snapshot: multi-line user message shows all lines" (fn []
                                                             (def w (setup))
                                                             (chat/output-user "first line\nsecond line\nthird line")
                                                             (def rows (render-chat w))
  # All three lines should appear in the rendered output
                                                             (def text (string/join rows "\n"))
                                                             (t/assert-truthy (string/find "user:" text))
                                                             (t/assert-truthy (string/find "first line" text))
                                                             (t/assert-truthy (string/find "second line" text))
                                                             (t/assert-truthy (string/find "third line" text))
  # Lines should be on separate rows
                                                             (var user-row nil)
                                                             (for i 0 (length rows)
                                                               (when (string/find "first line" (get rows i))
                                                                 (set user-row i)))
                                                             (t/assert-truthy user-row)
                                                             (t/assert-truthy (string/find "second line" (get rows (+ user-row 1))))
                                                             (t/assert-truthy (string/find "third line" (get rows (+ user-row 2))))))

(t/test "snapshot: error message shows label" (fn []
                                               (def w (setup))
                                               (chat/output-error "something failed")
                                               (def rows (render-chat w))
                                               (def bottom (get rows 9))
                                               (t/assert-truthy (string/find "err:" bottom))
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
                                                                 (t/assert-truthy (any-row-contains? rows "user:"))
                                                                 (t/assert-truthy (any-row-contains? rows "bash"))))

# ── Word wrapping snapshot ───────────────────────────────────

(t/test "snapshot: long lines wrap within viewport" (fn []
                                                     (def w (setup 30 10))
                                                     (chat/output-agent "This is a long agent response that should wrap across multiple lines in a narrow viewport")
                                                     (def rows (render-chat w 30 10))
                                                     (t/assert-truthy (any-row-contains? rows "gent:"))
  # Multiple rows should have content (wrapped)
                                                     (def non-empty (filter |(not= "" $) rows))
                                                     (t/assert-truthy (> (length non-empty) 1))))

(t/test "snapshot: word wrap breaks at spaces not mid-word" (fn []
                                                              (def w (setup 30 10))
  # "abcdef ghijkl" with prefix "         " (9 chars) = 23 chars per line avail
  # At width 29 (gutter takes 1), the first line is "   gent: abcdefghij klmnopqrs"
  # which is 29 chars. Next word won't fit → wrap at last space.
                                                              (chat/output-agent "one two three four five six seven eight nine ten eleven twelve")
                                                              (def rows (render-chat w 30 10))
                                                              (def non-empty (filter |(not= "" $) rows))
  # Check that no visible word is split across rows
  # (each row's trimmed text should not end mid-word, i.e. next row shouldn't
  # start with letters that continue the previous row's last word)
                                                              (t/assert-truthy (>= (length non-empty) 2))
                                                              (var prev-ends-letter false)
                                                              (each row non-empty
                                                                (def trimmed (string/trim row))
                                                                (when (> (length trimmed) 0)
                                                                  (def first-ch (get trimmed 0))
                                                                  (def starts-letter (and (>= first-ch (chr "a")) (<= first-ch (chr "z"))))
  # If previous row ended with a letter and this row starts with a letter,
  # the word was split (bad!)
                                                                  (when prev-ends-letter
                                                                    (t/assert-falsy starts-letter))
                                                                  (def last-ch (get trimmed (- (length trimmed) 1)))
                                                                  (set prev-ends-letter (and (>= last-ch (chr "a")) (<= last-ch (chr "z"))))))))

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
                                                                           (t/assert-truthy (find-row "user:"))
                                                                           (t/assert-truthy (find-row "gent:"))
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
                                                             (t/assert-truthy (string/find "user:" bottom))
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
  "Render the chat widget into a buffer and return the buffer.
   Width/height are content area; buffer is +2 for border."
  (default width 40)
  (default height 10)
  (def bw (+ width 2))
  (def bh (+ height 2))
  (def r (tui/rect 0 0 bw bh))
  (def buf (tui/buffer r))
  ((w :render) w r buf)
  buf)

(defn- content-cell
  "Get a cell from the content area (coordinates are relative to content, not buffer).
   Adds +1 to x and y to skip the border."
  [buf x y]
  (tui/buffer-get buf (+ x 1) (+ y 1)))

(t/test "snapshot: user message has gutter bar" (fn []
                                                 (def w (setup))
                                                 (chat/output-user "hello")
                                                 (def buf (render-buf w))
                                                 (def cell (content-cell buf 0 9))
                                                 (t/assert= (cell :ch) "▐")))

(t/test "snapshot: agent message has gutter bar" (fn []
                                                  (def w (setup))
                                                  (chat/output-agent "response text")
                                                  (def buf (render-buf w))
  # Agent text is on row 8; row 9 is the margin-bottom blank line
                                                  (def cell (content-cell buf 0 8))
                                                  (t/assert= (cell :ch) "▐")))

(t/test "snapshot: tool call has gutter bar" (fn []
                                              (def w (setup))
                                              (chat/output-tool "bash" "ls")
                                              (def buf (render-buf w))
                                              (def cell (content-cell buf 0 9))
                                              (t/assert= (cell :ch) "▐")))

(t/test "snapshot: tool result has gutter bar" (fn []
                                                (def w (setup))
                                                (chat/output-tool-result "ok")
                                                (def buf (render-buf w))
                                                (def cell (content-cell buf 0 9))
                                                (t/assert= (cell :ch) "▐")))

(t/test "snapshot: tool error and success both have gutter bars" (fn []
                                                                  (def w (setup 60 10))
                                                                  (chat/output-tool-result "success result" true)
                                                                  (chat/output-tool-result "Error: something failed" false)
                                                                  (def buf (render-buf w 60 10))
                                                                  (def success-cell (content-cell buf 0 8))
                                                                  (def error-cell (content-cell buf 0 9))
                                                                  (t/assert= (success-cell :ch) "▐")
                                                                  (t/assert= (error-cell :ch) "▐")))

(t/test "snapshot: gutter bar is only at column 0" (fn []
                                                    (def w (setup 40 10))
                                                    (chat/output-user "hi")
                                                    (def buf (render-buf w 40 10))
                                                    (def cell-start (content-cell buf 0 9))
                                                    (def cell-end (content-cell buf 39 9))
                                                    (t/assert= (cell-start :ch) "▐")
                                                    (t/assert-truthy (not= (cell-end :ch) "▐"))))

(t/test "snapshot: multi-line user message has gutter on all lines" (fn []
                                                                     (def w (setup))
                                                                     (chat/output-user "line A\nline B")
                                                                     (def rows (render-chat w))
  # Find the rows
                                                                     (var line-a-row nil)
                                                                     (for i 0 (length rows)
                                                                       (when (string/find "line A" (get rows i))
                                                                         (set line-a-row i)))
                                                                     (t/assert-truthy line-a-row)
  # Check the gutter bar on both rows
                                                                     (def buf (render-buf w))
                                                                     (def cell-a (content-cell buf 0 line-a-row))
                                                                     (def cell-b (content-cell buf 0 (+ line-a-row 1)))
                                                                     (t/assert= (cell-a :ch) "▐")
                                                                     (t/assert= (cell-b :ch) "▐")))

(t/test "snapshot: set-colors overrides a color" (fn []
                                                  (def w (setup))
                                                  (def custom-label (tui/style :fg [:rgb 99 99 99]))
                                                  (chat/set-colors @{:user-label custom-label})
                                                  (chat/output-user "custom label test")
                                                  (def buf (render-buf w))
                                                  (def cell (content-cell buf 0 9))
                                                  (t/assert= (get (cell :style) :fg) [:rgb 99 99 99])
                                                  (chat/set-theme :dark)))

(t/test "snapshot: set-theme switches to light" (fn []
                                                 (def w (setup))
                                                 (chat/set-theme :light)
                                                 (chat/output-user "light mode")
                                                 (def buf (render-buf w))
                                                 (def cell (content-cell buf 0 9))
                                                 (t/assert= (cell :ch) "▐")
                                                 (t/assert-truthy (get (cell :style) :fg))
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
                                                      (def cell (content-cell buf2 0 9))
                                                      (t/assert= (cell :ch) "▐")
                                                      (chat/set-theme :dark)))

(t/test "snapshot: visual-row scrolling moves exactly 1 row per step" (fn []
                                                                       (def w (setup 20 5))
  # Fill the viewport with enough content so scrolling works
                                                                       (for i 0 8 (chat/output (string "line " i)))
  # Add a line that wraps to 2 visual rows at width 20
                                                                       (chat/output "CCCCCCCCCCDDDDDDDDDDEEEEEEEEEE")
                                                                       (chat/output "last")

                                                                       (def rows0 (render-chat w 20 5))
                                                                       (t/assert-truthy (any-row-contains? rows0 "last"))

  # Scroll up by 1 visual row
                                                                       (widget/dispatch :chat {:type :scroll-line-up})
                                                                       (def rows1 (render-chat w 20 5))
  # "last" should be scrolled off the bottom
                                                                       (t/assert-truthy (not (any-row-contains? rows1 "last")))

  # Scroll back down
                                                                       (widget/dispatch :chat {:type :scroll-line-down})
                                                                       (def rows2 (render-chat w 20 5))
                                                                       (t/assert-truthy (any-row-contains? rows2 "last"))))

(t/test "snapshot: scroll clamps at max and returns to bottom" (fn []
                                                                (def w (setup 40 10))
                                                                (for i 0 5 (chat/output (string "line " i)))

  # Scroll up way past the content
                                                                (for _ 0 100 (widget/dispatch :chat {:type :scroll-line-up}))
                                                                (def rows-top (render-chat w))
                                                                (t/assert-truthy (any-row-contains? rows-top "line 0"))

  # Scroll back down way past bottom
                                                                (for _ 0 100 (widget/dispatch :chat {:type :scroll-line-down}))
                                                                (def rows-bottom (render-chat w))
                                                                (t/assert-truthy (any-row-contains? rows-bottom "line 4"))
                                                                (t/assert= (chat/get-scroll-offset) 0)))

(t/test "snapshot: streaming content hidden when scrolled up" (fn []
                                                               (def w (setup 40 8))
  
  # Fill with enough content to make scrolling possible
                                                               (for i 0 15 (chat/output (string "message " i)))
  
  # Scroll up so we're not at the bottom
                                                               (chat/set-scroll-offset 5)
  
  # Simulate streaming state (partial line in buffer)
  # Note: We can't easily test the private streaming state without deeper mocking,
  # but we can verify that the scroll offset logic is working correctly
  
                                                               (def rows (render-chat w 40 8))
  
  # When scrolled up, we should see older content, not the latest
                                                               (t/assert-truthy (not (any-row-contains? rows "message 14")))
                                                               (t/assert-truthy (any-row-contains? rows "message 9"))
  
  # The key insight: scroll offset > 0 means we're not at bottom
  # This is what the fix checks before showing streaming content
                                                               (t/assert-truthy (> (chat/get-scroll-offset) 0))))


(t/test "snapshot: scroll offset behavior demonstrates streaming fix" (fn []
                                                                       (def w (setup 40 8))
  
  # Fill with enough content to make scrolling possible
                                                                       (for i 0 15 (chat/output (string "message " i)))
  
  # Verify we can scroll up and content changes
                                                                       (def rows-at-bottom (render-chat w 40 8))
                                                                       (t/assert-truthy (any-row-contains? rows-at-bottom "message 14"))
  
  # Scroll up so we're not at the bottom
                                                                       (chat/set-scroll-offset 5)
                                                                       (def rows-scrolled (render-chat w 40 8))
                                                                       (t/assert-truthy (not (any-row-contains? rows-scrolled "message 14")))
                                                                       (t/assert-truthy (any-row-contains? rows-scrolled "message 9"))
  
  # The key insight: scroll offset > 0 means we're not at bottom
  # This is what the fix checks before showing streaming content
                                                                       (t/assert-truthy (> (chat/get-scroll-offset) 0))
  
  # Scroll back to bottom and verify
                                                                       (chat/set-scroll-offset 0)
                                                                       (def rows-back-bottom (render-chat w 40 8))
                                                                       (t/assert-truthy (any-row-contains? rows-back-bottom "message 14"))
                                                                       (t/assert= (chat/get-scroll-offset) 0)))

# ── Human-readable tool rendering ────────────────────────────

(t/test "snapshot: render-tool-call bash shows $ prefix" (fn []
                                                          (def w (setup 60 10))
                                                          (chat/render-tool-call "bash" @{:command "cargo build"})
                                                          (def rows (render-chat w 60 10))
                                                          (t/assert-truthy (any-row-contains? rows "Bash"))
                                                          (t/assert-truthy (any-row-contains? rows "$ cargo build"))))

(t/test "snapshot: render-tool-call read_file shows Read header" (fn []
                                                                  (def w (setup 60 10))
                                                                  (chat/render-tool-call "read_file" @{:path "janet/boot.janet"})
                                                                  (def rows (render-chat w 60 10))
                                                                  (t/assert-truthy (any-row-contains? rows "Read"))
                                                                  (t/assert-truthy (any-row-contains? rows "janet/boot.janet"))))

(t/test "snapshot: render-tool-call list_files shows List header" (fn []
                                                                   (def w (setup 60 10))
                                                                   (chat/render-tool-call "list_files" @{:path "janet/tools/"})
                                                                   (def rows (render-chat w 60 10))
                                                                   (t/assert-truthy (any-row-contains? rows "List"))
                                                                   (t/assert-truthy (any-row-contains? rows "janet/tools/"))))

(t/test "snapshot: render-tool-call use_skill shows Skill header" (fn []
                                                                   (def w (setup 60 10))
                                                                   (chat/render-tool-call "use_skill" @{:name "commit"})
                                                                   (def rows (render-chat w 60 10))
                                                                   (t/assert-truthy (any-row-contains? rows "Skill"))
                                                                   (t/assert-truthy (any-row-contains? rows "commit"))))

(t/test "snapshot: render-tool-call prompt_user shows Ask header" (fn []
                                                                   (def w (setup 60 10))
                                                                   (chat/render-tool-call "prompt_user" @{:type "confirm" :title "Continue?"})
                                                                   (def rows (render-chat w 60 10))
                                                                   (t/assert-truthy (any-row-contains? rows "Ask"))
                                                                   (t/assert-truthy (any-row-contains? rows "Continue?"))))

(t/test "snapshot: render-tool-call unknown tool falls through to generic" (fn []
                                                                            (def w (setup 60 10))
                                                                            (chat/render-tool-call "some_custom_tool" @{:foo "bar"})
                                                                            (def rows (render-chat w 60 10))
                                                                            (t/assert-truthy (any-row-contains? rows "some_custom_tool"))))

(t/test "snapshot: bash result hides exit code 0" (fn []
                                                   (def w (setup 60 10))
                                                   (chat/render-tool-result "bash" "exit code: 0\nstdout:\nall good\nstderr:\n")
                                                   (def rows (render-chat w 60 10))
                                                   (t/assert-truthy (any-row-contains? rows "all good"))
                                                   (t/assert-falsy (any-row-contains? rows "exit"))))

(t/test "snapshot: bash result shows non-zero exit code" (fn []
                                                          (def w (setup 60 10))
                                                          (chat/render-tool-result "bash" "exit code: 1\nstdout:\nstderr:\nerror: not found\n")
                                                          (def rows (render-chat w 60 10))
                                                          (t/assert-truthy (any-row-contains? rows "exit 1"))
                                                          (t/assert-truthy (any-row-contains? rows "error: not found"))))

(t/test "snapshot: read_file result has line numbers" (fn []
                                                       (def w (setup 60 10))
                                                       (chat/render-tool-result "read_file" "first line\nsecond line\nthird line")
                                                       (def rows (render-chat w 60 10))
                                                       (t/assert-truthy (any-row-contains? rows "1"))
                                                       (t/assert-truthy (any-row-contains? rows "first line"))
                                                       (t/assert-truthy (any-row-contains? rows "second line"))))

(t/test "snapshot: read_file error falls through to error display" (fn []
                                                                    (def w (setup 60 10))
                                                                    (chat/render-tool-result "read_file" "Error: file not found: missing.txt")
                                                                    (def rows (render-chat w 60 10))
                                                                    (t/assert-truthy (any-row-contains? rows "Error: file not found"))))

(t/test "snapshot: bash result with only stdout" (fn []
                                                  (def w (setup 60 10))
                                                  (chat/render-tool-result "bash" "exit code: 0\nstdout:\nhello world\nstderr:\n")
                                                  (def rows (render-chat w 60 10))
                                                  (t/assert-truthy (any-row-contains? rows "hello world"))
                                                  (t/assert-falsy (any-row-contains? rows "stdout"))
                                                  (t/assert-falsy (any-row-contains? rows "stderr"))))

# ── Table rendering at various widths ──────────────────────

(t/test "snapshot: wide table wraps cells at narrow width" (fn []
                                                             (def w (setup 50 20))
  # Feed a markdown table wider than 50 columns through the agent markdown parser
                                                             (chat/output-agent
                                                               (string "Here is a table:\n"
                                                                       "| Column A Long Name | Column B Long Name | Column C Long Name |\n"
                                                                       "| --- | --- | --- |\n"
                                                                       "| cell one value | cell two value | cell three value |\n"))
                                                             (def rows (render-chat w 50 20))
  # Table lines should be present (rendered with box-drawing chars)
                                                             (t/assert-truthy (any-row-contains? rows "│"))
  # All cell content should be visible (wrapped, not truncated)
  # The table is constrained to fit the available width, so no ellipsis
                                                             (var has-ellipsis false)
                                                             (each row rows
                                                               (when (string/find "…" row) (set has-ellipsis true)))
                                                             (t/assert-falsy has-ellipsis)
  # Verify the content is all visible somewhere in the rendered output
                                                             (def all-text (string/join rows "\n"))
                                                             (t/assert-truthy (string/find "Column A" all-text))
                                                             (t/assert-truthy (string/find "Column B" all-text))
                                                             (t/assert-truthy (string/find "Column C" all-text))
                                                             (t/assert-truthy (string/find "cell one" all-text))
                                                             (t/assert-truthy (string/find "cell two" all-text))
                                                             (t/assert-truthy (string/find "cell three" all-text))))

(t/test "snapshot: narrow table that fits is not truncated" (fn []
                                                             (def w (setup 60 20))
  # A small table that fits within 60 columns
                                                             (chat/output-agent
                                                               (string "| A | B |\n"
                                                                       "| - | - |\n"
                                                                       "| 1 | 2 |\n"))
                                                             (def rows (render-chat w 60 20))
  # Table should be present
                                                             (t/assert-truthy (any-row-contains? rows "│"))
  # No ellipsis — table fits
                                                             (var has-ellipsis false)
                                                             (each row rows
                                                               (when (string/find "…" row) (set has-ellipsis true)))
                                                             (t/assert-falsy has-ellipsis)))

(def pass (t/pass))
(def fail (t/fail))
