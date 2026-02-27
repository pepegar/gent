# Tests for tui/buffer
(use tui/rect)
(use tui/style)
(use tui/buffer)
(import test/helper :as t)

(print "── tui/buffer ──")

(t/test "buffer creates cells" (fn []
                                (def area (rect 0 0 3 2))
                                (def buf (buffer area))
                                (t/assert= (length (buf :cells)) 6)
                                (t/assert= ((buffer-get buf 0 0) :ch) " ")))

(t/test "buffer-set-char and buffer-get" (fn []
                                          (def buf (buffer (rect 0 0 5 5)))
                                          (buffer-set-char buf 2 3 "X")
                                          (t/assert= ((buffer-get buf 2 3) :ch) "X")
                                          (t/assert= ((buffer-get buf 0 0) :ch) " ")))

(t/test "buffer-set-char with style" (fn []
                                      (def buf (buffer (rect 0 0 5 5)))
                                      (def s (style :fg :red))
                                      (buffer-set-char buf 1 1 "Y" s)
                                      (def cell (buffer-get buf 1 1))
                                      (t/assert= (cell :ch) "Y")
                                      (t/assert= ((cell :style) :fg) :red)))

(t/test "buffer-set-string ASCII" (fn []
                                   (def buf (buffer (rect 0 0 10 1)))
                                   (buffer-set-string buf 0 0 "Hello")
                                   (t/assert= ((buffer-get buf 0 0) :ch) "H")
                                   (t/assert= ((buffer-get buf 4 0) :ch) "o")
                                   (t/assert= ((buffer-get buf 5 0) :ch) " ")))

(t/test "buffer-set-string UTF-8" (fn []
                                   (def buf (buffer (rect 0 0 10 1)))
                                   (buffer-set-string buf 0 0 "─X─")
  # "─" is 3 bytes in UTF-8 but should occupy 1 cell
                                   (t/assert= ((buffer-get buf 0 0) :ch) "─")
                                   (t/assert= ((buffer-get buf 1 0) :ch) "X")
                                   (t/assert= ((buffer-get buf 2 0) :ch) "─")))

(t/test "buffer-get out of bounds returns cell-empty" (fn []
                                                       (def buf (buffer (rect 0 0 3 3)))
                                                       (t/assert= ((buffer-get buf 10 10) :ch) " ")))

(t/test "buffer-fill" (fn []
                       (def buf (buffer (rect 0 0 3 3)))
                       (buffer-fill buf (rect 0 0 3 3) "#")
                       (t/assert= ((buffer-get buf 0 0) :ch) "#")
                       (t/assert= ((buffer-get buf 2 2) :ch) "#")))

(t/test "buffer->str produces ANSI" (fn []
                                     (def buf (buffer (rect 0 0 3 1)))
                                     (buffer-set-string buf 0 0 "Hi!")
                                     (def s (buffer->str buf))
                                     (t/assert-truthy (string/find "H" s))
                                     (t/assert-truthy (string/find "i" s))
                                     (t/assert-truthy (string/find "!" s))))

(t/test "buffer-diff empty when identical" (fn []
                                            (def a (buffer (rect 0 0 5 1)))
                                            (def b (buffer (rect 0 0 5 1)))
                                            (buffer-set-string a 0 0 "Hello")
                                            (buffer-set-string b 0 0 "Hello")
                                            (t/assert= (buffer-diff a b) "")))

(t/test "buffer-diff detects changes" (fn []
                                       (def a (buffer (rect 0 0 5 1)))
                                       (def b (buffer (rect 0 0 5 1)))
                                       (buffer-set-string a 0 0 "Hello")
                                       (buffer-set-string b 0 0 "Hallo")
                                       (def diff (buffer-diff a b))
                                       (t/assert-truthy (> (length diff) 0))
                                       (t/assert-truthy (string/find "a" diff))))

(t/test "buffer-diff non-contiguous changes" (fn []
  # Regression test: when two non-adjacent cells change on the same row,
  # the diff must emit cursor-moves for each gap, not just the first cell.
                                              (def a (buffer (rect 0 0 10 1)))
                                              (def b (buffer (rect 0 0 10 1)))
                                              (buffer-set-string a 0 0 "ABCDEFGHIJ")
                                              (buffer-set-string b 0 0 "A_CDE_GHIJ")
                                              (def diff (buffer-diff a b))
  # Diff should contain both "_" characters
                                              (t/assert-truthy (string/find "_" diff))
  # Apply diff to a fresh buffer to verify correctness:
  # We can't execute ANSI, but we can check that the diff contains
  # two cursor-move sequences (one for each non-contiguous change).
  # Cursor moves look like: ESC[row;colH
                                              (def cursor-moves (length (string/find-all "\x1b[" diff)))
  # At least 2 cursor-moves: one for col 1, one for col 5 (gap between them)
                                              (t/assert-truthy (>= cursor-moves 2))))

(t/test "buffer-diff contiguous changes use single cursor-move" (fn []
  # When changes are contiguous (no gap), only one cursor-move is needed.
                                                                 (def a (buffer (rect 0 0 10 1)))
                                                                 (def b (buffer (rect 0 0 10 1)))
                                                                 (buffer-set-string a 0 0 "AAAAAAAAAA")
                                                                 (buffer-set-string b 0 0 "AAABBAAAAA")
                                                                 (def diff (buffer-diff a b))
                                                                 (t/assert-truthy (string/find "B" diff))
  # Only 1 cursor-move needed (plus the style reset)
                                                                 (def cursor-moves (length (string/find-all "\x1b[" diff)))
  # Exactly 1 cursor-move + style codes
  # The \x1b[ count includes style sequences too, but cursor-moves have ;H pattern
                                                                 (def h-moves (length (string/find-all "H" diff)))
                                                                 (t/assert= h-moves 1)))

(t/test "buffer-diff multi-row non-contiguous" (fn []
  # Changes on different rows should each get cursor-moves.
                                                (def a (buffer (rect 0 0 5 3)))
                                                (def b (buffer (rect 0 0 5 3)))
                                                (buffer-set-string a 0 0 "AAAAA")
                                                (buffer-set-string a 0 1 "BBBBB")
                                                (buffer-set-string a 0 2 "CCCCC")
                                                (buffer-set-string b 0 0 "AAXAA")
                                                (buffer-set-string b 0 1 "BBBBB")  # unchanged
                                                (buffer-set-string b 0 2 "CCXCC")
                                                (def diff (buffer-diff a b))
                                                (t/assert-truthy (string/find "X" diff))
  # Should have cursor-moves for row 0 and row 2 at least
                                                (def h-moves (length (string/find-all "H" diff)))
                                                (t/assert-truthy (>= h-moves 2))))

# ── Plain text extraction tests ──────────────────────────────

(t/test "buffer-to-plain-rows returns array of strings" (fn []
                                                         (def buf (buffer (rect 0 0 5 3)))
                                                         (buffer-set-string buf 0 0 "Hello")
                                                         (buffer-set-string buf 0 1 "World")
                                                         (def rows (buffer-to-plain-rows buf))
                                                         (t/assert= (length rows) 3)
                                                         (t/assert= (get rows 0) "Hello")
                                                         (t/assert= (get rows 1) "World")
                                                         (t/assert= (get rows 2) "")))

(t/test "buffer-to-plain-rows trims trailing spaces" (fn []
                                                      (def buf (buffer (rect 0 0 10 1)))
                                                      (buffer-set-string buf 0 0 "Hi")
                                                      (def rows (buffer-to-plain-rows buf))
                                                      (t/assert= (get rows 0) "Hi")))

(t/test "buffer-to-plain-rows preserves leading spaces" (fn []
                                                         (def buf (buffer (rect 0 0 10 1)))
                                                         (buffer-set-string buf 3 0 "Hi")
                                                         (def rows (buffer-to-plain-rows buf))
                                                         (t/assert= (get rows 0) "   Hi")))

(t/test "buffer-to-text joins rows with newlines" (fn []
                                                   (def buf (buffer (rect 0 0 5 2)))
                                                   (buffer-set-string buf 0 0 "AB")
                                                   (buffer-set-string buf 0 1 "CD")
                                                   (t/assert= (buffer-to-text buf) "AB\nCD")))

(t/test "buffer-to-text empty buffer" (fn []
                                       (def buf (buffer (rect 0 0 3 2)))
                                       (t/assert= (buffer-to-text buf) "\n")))

(t/test "buffer-to-text with UTF-8" (fn []
                                     (def buf (buffer (rect 0 0 6 1)))
                                     (buffer-set-string buf 0 0 "─X─")
                                     (def rows (buffer-to-plain-rows buf))
                                     (t/assert= (get rows 0) "─X─")))

(t/test "buffer-to-text with styles ignores styles" (fn []
                                                     (def buf (buffer (rect 0 0 5 1)))
                                                     (buffer-set-string buf 0 0 "Red" (style :fg :red))
                                                     (def rows (buffer-to-plain-rows buf))
                                                     (t/assert= (get rows 0) "Red")))

(t/test "buffer-to-plain-rows with offset rect" (fn []
                                                 (def buf (buffer (rect 5 10 3 2)))
                                                 (buffer-set-char buf 5 10 "A")
                                                 (buffer-set-char buf 6 10 "B")
                                                 (buffer-set-char buf 5 11 "C")
                                                 (def rows (buffer-to-plain-rows buf))
                                                 (t/assert= (length rows) 2)
                                                 (t/assert= (get rows 0) "AB")
                                                 (t/assert= (get rows 1) "C")))

(def pass (t/pass))
(def fail (t/fail))
