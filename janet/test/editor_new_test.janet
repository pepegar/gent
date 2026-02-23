# Tests for widgets/editor_new — rich multiline editor.
(import core/buffers :as buffers)
(import widgets/editor_new :as ed)
(import test/helper :as t)

(print "── widgets/editor_new ──")

# ── 1. Coordinate helpers ───────────────────────────────────

(t/test "point->line-col at start" (fn []
  (t/assert= (ed/point->line-col "hello" 0) {:line 0 :col 0})))

(t/test "point->line-col mid-line" (fn []
  (t/assert= (ed/point->line-col "hello" 3) {:line 0 :col 3})))

(t/test "point->line-col at end of line" (fn []
  (t/assert= (ed/point->line-col "hello" 5) {:line 0 :col 5})))

(t/test "point->line-col second line" (fn []
  (t/assert= (ed/point->line-col "abc\ndef" 5) {:line 1 :col 1})))

(t/test "point->line-col at newline boundary" (fn []
  (t/assert= (ed/point->line-col "abc\ndef" 3) {:line 0 :col 3})))

(t/test "point->line-col after newline" (fn []
  (t/assert= (ed/point->line-col "abc\ndef" 4) {:line 1 :col 0})))

(t/test "point->line-col empty content" (fn []
  (t/assert= (ed/point->line-col "" 0) {:line 0 :col 0})))

(t/test "point->line-col three lines" (fn []
  (t/assert= (ed/point->line-col "a\nb\nc" 4) {:line 2 :col 0})))

(t/test "line-col->point round-trip single line" (fn []
  (def content "hello world")
  (for i 0 (+ (length content) 1)
    (def lc (ed/point->line-col content i))
    (def pt (ed/line-col->point content (lc :line) (lc :col)))
    (t/assert= pt i))))

(t/test "line-col->point round-trip multi-line" (fn []
  (def content "abc\ndef\nghi")
  (for i 0 (+ (length content) 1)
    (def lc (ed/point->line-col content i))
    (def pt (ed/line-col->point content (lc :line) (lc :col)))
    (t/assert= pt i))))

(t/test "line-start-offset" (fn []
  (def content "abc\ndef\nghi")
  (t/assert= (ed/line-start-offset content 0) 0)
  (t/assert= (ed/line-start-offset content 1) 4)
  (t/assert= (ed/line-start-offset content 2) 8)))

(t/test "line-end-offset" (fn []
  (def content "abc\ndef\nghi")
  (t/assert= (ed/line-end-offset content 0) 3)
  (t/assert= (ed/line-end-offset content 1) 7)
  (t/assert= (ed/line-end-offset content 2) 11)))

# ── 2. Word wrap ────────────────────────────────────────────

(t/test "wrap-line short line no wrap" (fn []
  (def segs (ed/wrap-line "hello" 80))
  (t/assert= (length segs) 1)
  (t/assert= ((first segs) :text) "hello")))

(t/test "wrap-line empty line" (fn []
  (def segs (ed/wrap-line "" 80))
  (t/assert= (length segs) 1)
  (t/assert= ((first segs) :text) "")))

(t/test "wrap-line exact width" (fn []
  (def segs (ed/wrap-line "abcde" 5))
  (t/assert= (length segs) 1)
  (t/assert= ((first segs) :text) "abcde")))

(t/test "wrap-line word overflow" (fn []
  (def segs (ed/wrap-line "hello world" 8))
  (t/assert= (length segs) 2)
  (t/assert= ((get segs 0) :text) "hello ")
  (t/assert= ((get segs 1) :text) "world")))

(t/test "wrap-line long single word hard-break" (fn []
  (def segs (ed/wrap-line "abcdefghij" 5))
  (t/assert= (length segs) 2)
  (t/assert= ((get segs 0) :text) "abcde")
  (t/assert= ((get segs 1) :text) "fghij")))

(t/test "wrap-line multiple segments" (fn []
  (def segs (ed/wrap-line "aaa bbb ccc ddd" 8))
  (t/assert= (length segs) 2)))

(t/test "wrap-line offsets are correct" (fn []
  (def segs (ed/wrap-line "hello world" 8))
  (t/assert= ((get segs 0) :start) 0)
  (t/assert= ((get segs 0) :end) 6)
  (t/assert= ((get segs 1) :start) 6)
  (t/assert= ((get segs 1) :end) 11)))

# ── 3. Visual line layout ──────────────────────────────────

(t/test "compute-visual-lines single line" (fn []
  (def vlines (ed/compute-visual-lines "hello" 80))
  (t/assert= (length vlines) 1)
  (t/assert= ((first vlines) :text) "hello")
  (t/assert= ((first vlines) :start) 0)
  (t/assert= ((first vlines) :end) 5)))

(t/test "compute-visual-lines two lines" (fn []
  (def vlines (ed/compute-visual-lines "abc\ndef" 80))
  (t/assert= (length vlines) 2)
  (t/assert= ((get vlines 0) :text) "abc")
  (t/assert= ((get vlines 0) :start) 0)
  (t/assert= ((get vlines 1) :text) "def")
  (t/assert= ((get vlines 1) :start) 4)))

(t/test "compute-visual-lines with wrapping" (fn []
  (def vlines (ed/compute-visual-lines "hello world" 8))
  (t/assert= (length vlines) 2)))

(t/test "compute-visual-lines empty content" (fn []
  (def vlines (ed/compute-visual-lines "" 80))
  (t/assert= (length vlines) 1)
  (t/assert= ((first vlines) :text) "")))

# ── 4. Coordinate mapping ──────────────────────────────────

(t/test "point->visual simple" (fn []
  (def state (ed/new 80 10 "hello"))
  (buffers/set-point (state :buf) 3)
  (def vis (ed/point->visual state))
  (t/assert= (vis :row) 0)
  (t/assert= (vis :col) 3)))

(t/test "point->visual second line" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 5)
  (def vis (ed/point->visual state))
  (t/assert= (vis :row) 1)
  (t/assert= (vis :col) 1)))

(t/test "point->visual at start" (fn []
  (def state (ed/new 80 10 "hello"))
  (buffers/set-point (state :buf) 0)
  (def vis (ed/point->visual state))
  (t/assert= (vis :row) 0)
  (t/assert= (vis :col) 0)))

(t/test "visual->point round-trip" (fn []
  (def state (ed/new 80 10 "abc\ndef\nghi"))
  (def content (ed/text state))
  (for i 0 (+ (length content) 1)
    (buffers/set-point (state :buf) i)
    (def vis (ed/point->visual state))
    (def pt (ed/visual->point state (vis :row) (vis :col)))
    (t/assert= pt i))))

# ── 5. Character insert ────────────────────────────────────

(t/test "insert at end" (fn []
  (def state (ed/new 80 10))
  (ed/insert-char state "h")
  (ed/insert-char state "i")
  (t/assert= (ed/text state) "hi")
  (t/assert= (ed/point state) 2)))

(t/test "insert at start" (fn []
  (def state (ed/new 80 10 "ello"))
  (buffers/set-point (state :buf) 0)
  (ed/insert-char state "h")
  (t/assert= (ed/text state) "hello")
  (t/assert= (ed/point state) 1)))

(t/test "insert in middle" (fn []
  (def state (ed/new 80 10 "hllo"))
  (buffers/set-point (state :buf) 1)
  (ed/insert-char state "e")
  (t/assert= (ed/text state) "hello")
  (t/assert= (ed/point state) 2)))

# ── 6. Newline insert ──────────────────────────────────────

(t/test "newline at end" (fn []
  (def state (ed/new 80 10 "abc"))
  (ed/insert-newline state)
  (t/assert= (ed/text state) "abc\n")
  (t/assert= (ed/point state) 4)))

(t/test "newline in middle" (fn []
  (def state (ed/new 80 10 "abcdef"))
  (buffers/set-point (state :buf) 3)
  (ed/insert-newline state)
  (t/assert= (ed/text state) "abc\ndef")
  (t/assert= (ed/point state) 4)))

(t/test "newline on empty buffer" (fn []
  (def state (ed/new 80 10))
  (ed/insert-newline state)
  (t/assert= (ed/text state) "\n")
  (t/assert= (ed/point state) 1)))

# ── 7. Backspace ───────────────────────────────────────────

(t/test "backspace at mid-line" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/delete-back state)
  (t/assert= (ed/text state) "hell")
  (t/assert= (ed/point state) 4)))

(t/test "backspace at line start joins lines" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 4)
  (ed/delete-back state)
  (t/assert= (ed/text state) "abcdef")
  (t/assert= (ed/point state) 3)))

(t/test "backspace at buffer start is no-op" (fn []
  (def state (ed/new 80 10 "hello"))
  (buffers/set-point (state :buf) 0)
  (ed/delete-back state)
  (t/assert= (ed/text state) "hello")
  (t/assert= (ed/point state) 0)))

# ── 8. Delete forward ─────────────────────────────────────

(t/test "delete forward at mid-line" (fn []
  (def state (ed/new 80 10 "hello"))
  (buffers/set-point (state :buf) 0)
  (ed/delete-forward state)
  (t/assert= (ed/text state) "ello")
  (t/assert= (ed/point state) 0)))

(t/test "delete forward at line end joins" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 3)
  (ed/delete-forward state)
  (t/assert= (ed/text state) "abcdef")
  (t/assert= (ed/point state) 3)))

(t/test "delete forward at buffer end is no-op" (fn []
  (def state (ed/new 80 10 "hi"))
  (ed/delete-forward state)
  (t/assert= (ed/text state) "hi")
  (t/assert= (ed/point state) 2)))

# ── 9. Word operations ────────────────────────────────────

(t/test "move-word-right" (fn []
  (def state (ed/new 80 10 "hello world foo"))
  (buffers/set-point (state :buf) 0)
  (ed/move-word-right state)
  (t/assert= (ed/point state) 6)
  (ed/move-word-right state)
  (t/assert= (ed/point state) 12)))

(t/test "move-word-left" (fn []
  (def state (ed/new 80 10 "hello world foo"))
  (ed/move-word-left state)
  (t/assert= (ed/point state) 12)
  (ed/move-word-left state)
  (t/assert= (ed/point state) 6)))

(t/test "delete-word-back" (fn []
  (def state (ed/new 80 10 "hello world"))
  (ed/delete-word-back state)
  (t/assert= (ed/text state) "hello ")
  (t/assert= (ed/point state) 6)))

(t/test "delete-word-back at start is no-op" (fn []
  (def state (ed/new 80 10 "hello"))
  (buffers/set-point (state :buf) 0)
  (ed/delete-word-back state)
  (t/assert= (ed/text state) "hello")
  (t/assert= (ed/point state) 0)))

(t/test "delete-word-forward" (fn []
  (def state (ed/new 80 10 "hello world"))
  (buffers/set-point (state :buf) 0)
  (ed/delete-word-forward state)
  (t/assert= (ed/text state) " world")
  (t/assert= (ed/point state) 0)))

(t/test "delete-word-forward pushes to kill ring" (fn []
  (def state (ed/new 80 10 "hello world"))
  (buffers/set-point (state :buf) 0)
  (ed/delete-word-forward state)
  (t/assert= (length (state :kill-ring)) 1)
  (t/assert= (last (state :kill-ring)) "hello")))

# ── 10. Kill/Yank ─────────────────────────────────────────

(t/test "kill-to-end from middle" (fn []
  (def state (ed/new 80 10 "hello world"))
  (buffers/set-point (state :buf) 5)
  (ed/kill-to-end state)
  (t/assert= (ed/text state) "hello")
  (t/assert= (ed/point state) 5)
  (t/assert= (last (state :kill-ring)) " world")))

(t/test "kill-to-end at end of line joins" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 3)
  (ed/kill-to-end state)
  (t/assert= (ed/text state) "abcdef")
  (t/assert= (ed/point state) 3)
  (t/assert= (last (state :kill-ring)) "\n")))

(t/test "kill-to-start" (fn []
  (def state (ed/new 80 10 "hello world"))
  (buffers/set-point (state :buf) 6)
  (ed/kill-to-start state)
  (t/assert= (ed/text state) "world")
  (t/assert= (ed/point state) 0)
  (t/assert= (last (state :kill-ring)) "hello ")))

(t/test "kill-to-start at line start is no-op" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 4)
  (ed/kill-to-start state)
  (t/assert= (ed/text state) "abc\ndef")
  (t/assert= (ed/point state) 4)))

(t/test "yank inserts killed text" (fn []
  (def state (ed/new 80 10 "hello world"))
  (buffers/set-point (state :buf) 5)
  (ed/kill-to-end state)
  (t/assert= (ed/text state) "hello")
  (ed/yank state)
  (t/assert= (ed/text state) "hello world")
  (t/assert= (ed/point state) 11)))

(t/test "yank on empty kill ring is no-op" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/yank state)
  (t/assert= (ed/text state) "hello")
  (t/assert= (ed/point state) 5)))

(t/test "yank-pop replaces last yank" (fn []
  (def state (ed/new 80 10 "aaa bbb ccc"))
  (buffers/set-point (state :buf) 4)
  (ed/kill-to-end state)
  # killed "bbb ccc", text is "aaa "
  (buffers/set-point (state :buf) 0)
  (ed/kill-to-end state)
  # killed "aaa ", text is ""
  # kill-ring: ["bbb ccc", "aaa "]
  (ed/yank state)
  (t/assert= (ed/text state) "aaa ")
  (ed/yank-pop state)
  (t/assert= (ed/text state) "bbb ccc")))

(t/test "kill ring accumulation" (fn []
  (def state (ed/new 80 10 "one two three"))
  (ed/delete-word-back state)
  (ed/delete-word-back state)
  (ed/delete-word-back state)
  (t/assert= (length (state :kill-ring)) 3)))

# ── 11. Cursor movement ───────────────────────────────────

(t/test "move-left" (fn []
  (def state (ed/new 80 10 "abc"))
  (ed/move-left state)
  (t/assert= (ed/point state) 2)))

(t/test "move-left at start is no-op" (fn []
  (def state (ed/new 80 10 "abc"))
  (buffers/set-point (state :buf) 0)
  (ed/move-left state)
  (t/assert= (ed/point state) 0)))

(t/test "move-right" (fn []
  (def state (ed/new 80 10 "abc"))
  (buffers/set-point (state :buf) 0)
  (ed/move-right state)
  (t/assert= (ed/point state) 1)))

(t/test "move-right at end is no-op" (fn []
  (def state (ed/new 80 10 "abc"))
  (ed/move-right state)
  (t/assert= (ed/point state) 3)))

(t/test "move-line-start" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 6)
  (ed/move-line-start state)
  (t/assert= (ed/point state) 4)))

(t/test "move-line-end" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 4)
  (ed/move-line-end state)
  (t/assert= (ed/point state) 7)))

(t/test "move-buffer-start" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (ed/move-buffer-start state)
  (t/assert= (ed/point state) 0)))

(t/test "move-buffer-end" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 0)
  (ed/move-buffer-end state)
  (t/assert= (ed/point state) 7)))

(t/test "move-up" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 5)
  (ed/move-up state)
  (t/assert= (ed/point state) 1)))

(t/test "move-up at first line is no-op" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 1)
  (ed/move-up state)
  (t/assert= (ed/point state) 1)))

(t/test "move-down" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 1)
  (ed/move-down state)
  (t/assert= (ed/point state) 5)))

(t/test "move-down at last line is no-op" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 5)
  (ed/move-down state)
  (t/assert= (ed/point state) 5)))

(t/test "move-up/down sticky-col" (fn []
  (def state (ed/new 80 10 "abcde\nab\nabcde"))
  (buffers/set-point (state :buf) 4)
  # at line 0, col 4
  (ed/move-down state)
  # line 1 only has 2 chars, so col clamped to 2
  (t/assert= (ed/point state) 8)
  # sticky-col should be 4
  (ed/move-down state)
  # line 2 has 5 chars, sticky-col 4 applies
  (t/assert= (ed/point state) 13)))

(t/test "sticky-col clears on horizontal move" (fn []
  (def state (ed/new 80 10 "abcde\nab\nabcde"))
  (buffers/set-point (state :buf) 4)
  (ed/move-down state)
  (t/assert-truthy (state :sticky-col))
  (ed/move-left state)
  (t/assert= (state :sticky-col) nil)))

# ── 12. Scrolling ─────────────────────────────────────────

(t/test "scroll adjusts when cursor below viewport" (fn []
  (def state (ed/new 80 3 "a\nb\nc\nd\ne"))
  (buffers/set-point (state :buf) 0)
  (put state :scroll 0)
  (buffers/set-point (state :buf) 8)
  (ed/move-right state)
  # cursor at end, visual row 4, viewport only 3 rows
  (t/assert-truthy (>= (state :scroll) 2))))

(t/test "scroll adjusts when cursor above viewport" (fn []
  (def state (ed/new 80 3 "a\nb\nc\nd\ne"))
  (put state :scroll 3)
  (buffers/set-point (state :buf) 0)
  (ed/move-left state)
  (t/assert= (state :scroll) 0)))

(t/test "page-down moves by viewport height" (fn []
  (def state (ed/new 80 2 "a\nb\nc\nd\ne\nf"))
  (buffers/set-point (state :buf) 0)
  (put state :scroll 0)
  (ed/page-down state)
  (def vis (ed/point->visual state))
  (t/assert= (vis :row) 2)))

(t/test "page-up moves by viewport height" (fn []
  (def state (ed/new 80 2 "a\nb\nc\nd\ne\nf"))
  (buffers/set-point (state :buf) 8)
  (ed/page-up state)
  (def vis (ed/point->visual state))
  (t/assert= (vis :row) 2)))

# ── 13. Undo/Redo ─────────────────────────────────────────

(t/test "single undo" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/insert-char state "!")
  (t/assert= (ed/text state) "hello!")
  (ed/undo state)
  (t/assert= (ed/text state) "hello")))

(t/test "multi-step undo" (fn []
  (def state (ed/new 80 10))
  (ed/insert-char state "a")
  (ed/insert-char state "b")
  (ed/insert-char state "c")
  (t/assert= (ed/text state) "abc")
  (ed/undo state)
  (t/assert= (ed/text state) "ab")
  (ed/undo state)
  (t/assert= (ed/text state) "a")
  (ed/undo state)
  (t/assert= (ed/text state) "")))

(t/test "redo after undo" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/insert-char state "!")
  (ed/undo state)
  (t/assert= (ed/text state) "hello")
  (ed/redo state)
  (t/assert= (ed/text state) "hello!")))

(t/test "redo cleared by new edit" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/insert-char state "!")
  (ed/undo state)
  (ed/insert-char state "?")
  (t/assert= (ed/text state) "hello?")
  (ed/redo state)
  # redo stack was cleared, so still "hello?"
  (t/assert= (ed/text state) "hello?")))

(t/test "undo on empty stack is no-op" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/undo state)
  (t/assert= (ed/text state) "hello")))

# ── 14. Bulk operations ───────────────────────────────────

(t/test "insert-text with newlines" (fn []
  (def state (ed/new 80 10))
  (ed/insert-text state "hello\nworld")
  (t/assert= (ed/text state) "hello\nworld")
  (t/assert= (ed/point state) 11)))

(t/test "set-text replaces all" (fn []
  (def state (ed/new 80 10 "old content"))
  (ed/set-text state "new content")
  (t/assert= (ed/text state) "new content")))

(t/test "set-text with empty string" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/set-text state "")
  (t/assert= (ed/text state) "")
  (t/assert= (ed/point state) 0)))

# ── 15. Resize ────────────────────────────────────────────

(t/test "resize changes dimensions" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/resize state 40 5)
  (t/assert= (state :width) 40)
  (t/assert= (state :height) 5)))

(t/test "resize cursor stays valid" (fn []
  (def state (ed/new 80 10 "hello\nworld"))
  (ed/resize state 40 5)
  (t/assert-truthy (<= (ed/point state) (length (ed/text state))))))

# ── 16. External editor ──────────────────────────────────

(t/test "open-external returns sentinel" (fn []
  (def state (ed/new 80 10 "hello"))
  (def result (ed/open-external state))
  (t/assert= (result :action) :open-external)
  (t/assert= (result :text) "hello")))

# ── 17. Edge cases ───────────────────────────────────────

(t/test "empty buffer operations" (fn []
  (def state (ed/new 80 10))
  (t/assert= (ed/text state) "")
  (t/assert= (ed/point state) 0)
  (ed/delete-back state)
  (t/assert= (ed/text state) "")
  (ed/delete-forward state)
  (t/assert= (ed/text state) "")
  (ed/move-left state)
  (t/assert= (ed/point state) 0)
  (ed/move-right state)
  (t/assert= (ed/point state) 0)))

(t/test "single char buffer" (fn []
  (def state (ed/new 80 10 "x"))
  (t/assert= (ed/text state) "x")
  (t/assert= (ed/point state) 1)
  (ed/delete-back state)
  (t/assert= (ed/text state) "")
  (t/assert= (ed/point state) 0)))

(t/test "render returns correct structure" (fn []
  (def state (ed/new 80 5 "hello\nworld"))
  (def r (ed/render state))
  (t/assert-truthy (r :lines))
  (t/assert-truthy (r :cursor))
  (t/assert= (length (r :lines)) 5)
  (t/assert= (get (r :lines) 0) "hello")
  (t/assert= (get (r :lines) 1) "world")))

(t/test "render with scrolling" (fn []
  (def state (ed/new 80 2 "a\nb\nc\nd"))
  (put state :scroll 1)
  (def r (ed/render state))
  (t/assert= (get (r :lines) 0) "b")
  (t/assert= (get (r :lines) 1) "c")))

(t/test "handle-key printable char" (fn []
  (def state (ed/new 80 10))
  (ed/handle-key state @{:key "a" :ctrl false :alt false :shift false})
  (t/assert= (ed/text state) "a")))

(t/test "handle-key backspace" (fn []
  (def state (ed/new 80 10 "ab"))
  (ed/handle-key state @{:key :backspace :ctrl false :alt false :shift false})
  (t/assert= (ed/text state) "a")))

(t/test "handle-key ctrl+a moves to line start" (fn []
  (def state (ed/new 80 10 "hello"))
  (ed/handle-key state @{:key "a" :ctrl true :alt false :shift false})
  (t/assert= (ed/point state) 0)))

(t/test "handle-key ctrl+e moves to line end" (fn []
  (def state (ed/new 80 10 "hello"))
  (buffers/set-point (state :buf) 0)
  (ed/handle-key state @{:key "e" :ctrl true :alt false :shift false})
  (t/assert= (ed/point state) 5)))

(t/test "handle-key ctrl+g returns open-external" (fn []
  (def state (ed/new 80 10 "test"))
  (def result (ed/handle-key state @{:key "g" :ctrl true :alt false :shift false}))
  (t/assert= (result :action) :open-external)))

(t/test "line-col query" (fn []
  (def state (ed/new 80 10 "abc\ndef"))
  (buffers/set-point (state :buf) 5)
  (def lc (ed/line-col state))
  (t/assert= (lc :line) 1)
  (t/assert= (lc :col) 1)))

(t/test "cursor-visual accounts for scroll" (fn []
  (def state (ed/new 80 3 "a\nb\nc\nd\ne"))
  (put state :scroll 2)
  (buffers/set-point (state :buf) 6)
  (def cv (ed/cursor-visual state))
  (t/assert= (cv :row) 1)))

(def pass (t/pass))
(def fail (t/fail))
