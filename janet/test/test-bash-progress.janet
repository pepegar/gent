# test/test-bash-progress.janet — Snapshot tests for live bash progress display.
#
# Tests the inline progress block that shows the last N lines of bash output
# while a command is running.

(import test/fake-http :as fake)
(fake/install (curenv))

(import widgets/chat :as chat)
(import core/widget :as widget)
(import tui)
(import test/helper :as t)

(print "── bash progress ──")

# ── Helpers ────────────────────────────────────────────────────

(defn- setup [&opt width height]
  (default width 60)
  (default height 15)
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
  (default width 60)
  (default height 15)
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

(defn- any-row-contains? [rows text]
  (some |(not (nil? (string/find text $))) rows))

(defn- find-row [rows text]
  (var found nil)
  (for i 0 (length rows)
    (when (and (nil? found) (string/find text (get rows i)))
      (set found i)))
  found)

# ── Tests ──────────────────────────────────────────────────────

(t/test "bash progress: update shows last lines in scrollback" (fn []
                                                                (def w (setup))
                                                                (chat/output-bash @{:command "make build"})
                                                                (chat/update-bash-progress "line 1\nline 2\nline 3\n")
                                                                (def rows (render-chat w))
                                                                (t/assert-truthy (any-row-contains? rows "Bash"))
                                                                (t/assert-truthy (any-row-contains? rows "output"))
                                                                (t/assert-truthy (any-row-contains? rows "line 1"))
                                                                (t/assert-truthy (any-row-contains? rows "line 2"))
                                                                (t/assert-truthy (any-row-contains? rows "line 3"))))

(t/test "bash progress: shows only last 5 lines for long output" (fn []
                                                                  (def w (setup))
                                                                  (chat/output-bash @{:command "long"})
                                                                  (def output (string/join (seq [i :range [0 10]] (string "out " i)) "\n"))
                                                                  (chat/update-bash-progress output)
                                                                  (def rows (render-chat w))
  # Should show "hidden" indicator and last 5 lines
                                                                  (t/assert-truthy (any-row-contains? rows "hidden"))
                                                                  (t/assert-truthy (any-row-contains? rows "out 5"))
                                                                  (t/assert-truthy (any-row-contains? rows "out 9"))
  # First lines should NOT be visible
                                                                  (t/assert-falsy (any-row-contains? rows "out 0"))
                                                                  (t/assert-falsy (any-row-contains? rows "out 1"))))

(t/test "bash progress: update replaces previous progress" (fn []
                                                            (def w (setup))
                                                            (chat/output-bash @{:command "test"})
                                                            (chat/update-bash-progress "first\n")
                                                            (chat/update-bash-progress "first\nsecond\n")
                                                            (def rows (render-chat w))
  # Should have "first" and "second" but only ONE header line
                                                            (t/assert-truthy (any-row-contains? rows "first"))
                                                            (t/assert-truthy (any-row-contains? rows "second"))
  # Count header lines - should be exactly 1
                                                            (var header-count 0)
                                                            (each row rows
                                                              (when (string/find "output" row) (++ header-count)))
                                                            (t/assert= header-count 1)))

(t/test "bash progress: remove cleans all progress lines" (fn []
                                                           (def w (setup))
                                                           (chat/output-bash @{:command "test"})
                                                           (chat/update-bash-progress "hello\nworld\n")
  # Verify progress is visible
                                                           (def rows-before (render-chat w))
                                                           (t/assert-truthy (any-row-contains? rows-before "hello"))
  # Now simulate tool completion by checking the scrollback directly
                                                           (def sb (chat/get-scrollback))
                                                           (def progress-count (length (filter |(get $ :progress) sb)))
                                                           (t/assert-truthy (> progress-count 0))
  # Remove progress lines (what finish-current-async-tool does)
                                                           (chat/update-bash-progress "")  # Empty triggers no new lines after removal
  # Actually, let's verify remove-progress-lines via a fresh update
                                                           (def sb-after (chat/get-scrollback))
  # After empty update, all progress lines should be gone
                                                           (def progress-after (length (filter |(get $ :progress) sb-after)))
                                                           (t/assert= progress-after 0)))

(t/test "bash progress: preserves tool call header" (fn []
                                                     (def w (setup))
                                                     (chat/output-bash @{:command "cargo build"})
                                                     (chat/update-bash-progress "Compiling gent\nFinished build\n")
                                                     (def rows (render-chat w))
  # Both the tool call header and progress should be visible
                                                     (t/assert-truthy (any-row-contains? rows "Bash"))
                                                     (t/assert-truthy (any-row-contains? rows "$ cargo build"))
                                                     (t/assert-truthy (any-row-contains? rows "Compiling gent"))
                                                     (t/assert-truthy (any-row-contains? rows "Finished build"))))

(t/test "bash progress: progress has gutter bar" (fn []
                                                  (def w (setup))
                                                  (chat/output-bash @{:command "test"})
                                                  (chat/update-bash-progress "some output\n")
                                                  (def bw 62)
                                                  (def bh 17)
                                                  (def r (tui/rect 0 0 bw bh))
                                                  (def buf (tui/buffer r))
                                                  ((w :render) w r buf)
  # Find a row with "some output" and check gutter
                                                  (var found-gutter false)
                                                  (for row 0 15
                                                    (def chars @[])
                                                    (for col 0 60
                                                      (def cell (tui/buffer-get buf (+ col 1) (+ row 1)))
                                                      (array/push chars (cell :ch)))
                                                    (def text (string ;chars))
                                                    (when (string/find "some output" text)
                                                      (def gutter-cell (tui/buffer-get buf 1 (+ row 1)))
                                                      (when (= (gutter-cell :ch) "▐")
                                                        (set found-gutter true))))
                                                  (t/assert-truthy found-gutter)))

(t/test "bash progress: empty output shows nothing" (fn []
                                                     (def w (setup))
                                                     (chat/output-bash @{:command "test"})
                                                     (def sb-before (length (chat/get-scrollback)))
                                                     (chat/update-bash-progress "")
                                                     (def sb-after (length (chat/get-scrollback)))
  # No progress lines should be added for empty output
                                                     (t/assert= sb-before sb-after)))

(t/test "bash progress: trailing newlines are trimmed" (fn []
                                                        (def w (setup))
                                                        (chat/output-bash @{:command "test"})
                                                        (chat/update-bash-progress "hello\n\n\n\n")
                                                        (def rows (render-chat w))
                                                        (t/assert-truthy (any-row-contains? rows "hello"))
  # Should have header + 1 content line, not 4 blank lines
                                                        (def sb (chat/get-scrollback))
                                                        (def progress-lines (filter |(get $ :progress) sb))
                                                        (t/assert= (length progress-lines) 2)))  # header + "hello"

(def pass (t/pass))
(def fail (t/fail))