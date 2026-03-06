# test/test-charwidth.janet — Tests for Unicode character display width.

(import test/fake-http :as fake)
(fake/install (curenv))

(import tui)
(import tui/charwidth :as cw)
(import tui/buffer :as buf)
(import tui/text :as text)
(import widgets/chat :as chat)
(import core/widget :as widget)
(import test/helper :as t)

(print "── tui/charwidth ──")

# ── char-width basics ──────────────────────────────────────────

(t/test "ASCII is 1-wide" (fn []
  (t/assert= (cw/char-width "a") 1)
  (t/assert= (cw/char-width "Z") 1)
  (t/assert= (cw/char-width "5") 1)
  (t/assert= (cw/char-width " ") 1)))

(t/test "control chars are 0-wide" (fn []
  (t/assert= (cw/char-width (string/from-bytes 0)) 0)
  (t/assert= (cw/char-width (string/from-bytes 0x0A)) 0)
  (t/assert= (cw/char-width (string/from-bytes 0x1B)) 0)))

(t/test "warning sign is 2-wide" (fn []
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))  # ⚠ U+26A0
  (t/assert= (cw/char-width warning) 2)))

(t/test "CJK ideograph is 2-wide" (fn []
  (def han (string/from-bytes 0xE4 0xB8 0xAD))  # 中 U+4E2D
  (t/assert= (cw/char-width han) 2)))

(t/test "fullwidth latin is 2-wide" (fn []
  (def fw-a (string/from-bytes 0xEF 0xBC 0xA1))  # Ａ U+FF21
  (t/assert= (cw/char-width fw-a) 2)))

(t/test "combining mark is 0-wide" (fn []
  (def combining (string/from-bytes 0xCC 0x81))  # U+0301 combining acute
  (t/assert= (cw/char-width combining) 0)))

(t/test "regular symbols are 1-wide" (fn []
  (t/assert= (cw/char-width "│") 1)
  (t/assert= (cw/char-width "─") 1)
  (t/assert= (cw/char-width "╭") 1)))

# ── string-width ──────────────────────────────────────────────

(t/test "string-width ASCII" (fn []
  (t/assert= (cw/string-width "hello") 5)))

(t/test "string-width with warning sign" (fn []
  (def s (string "a" (string/from-bytes 0xE2 0x9A 0xA0) "b"))  # a⚠b
  (t/assert= (cw/string-width s) 4)))  # a=1, ⚠=2, b=1

(t/test "string-width CJK" (fn []
  (def s (string/from-bytes 0xE4 0xB8 0xAD 0xE6 0x96 0x87))  # 中文
  (t/assert= (cw/string-width s) 4)))

(t/test "string-width empty" (fn []
  (t/assert= (cw/string-width "") 0)))

# ── buffer-set-string with wide chars ─────────────────────────

(print "── buffer wide char handling ──")

(t/test "buffer-set-string places wide char correctly" (fn []
  (def area (tui/rect 0 0 20 1))
  (def b (tui/buffer area))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (tui/buffer-set-string b 0 0 (string "a" warning "b") (tui/style))
  # a at col 0, ⚠ at col 1, continuation at col 2, b at col 3
  (t/assert= ((tui/buffer-get b 0 0) :ch) "a")
  (t/assert= ((tui/buffer-get b 1 0) :ch) warning)
  (t/assert= ((tui/buffer-get b 2 0) :ch) "")    # continuation
  (t/assert= ((tui/buffer-get b 3 0) :ch) "b")))

(t/test "buffer-set-string wide char at end clips" (fn []
  (def area (tui/rect 0 0 5 1))
  (def b (tui/buffer area))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  # "abc⚠" — ⚠ needs cols 3-4, fits in width 5
  (tui/buffer-set-string b 0 0 (string "abc" warning) (tui/style))
  (t/assert= ((tui/buffer-get b 3 0) :ch) warning)
  (t/assert= ((tui/buffer-get b 4 0) :ch) "")))

(t/test "buffer-set-string wide char overflow clips" (fn []
  (def area (tui/rect 0 0 4 1))
  (def b (tui/buffer area))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  # "abc⚠" — ⚠ needs cols 3-4, but only col 3 available (width 4)
  (tui/buffer-set-string b 0 0 (string "abc" warning) (tui/style))
  (t/assert= ((tui/buffer-get b 0 0) :ch) "a")
  (t/assert= ((tui/buffer-get b 1 0) :ch) "b")
  (t/assert= ((tui/buffer-get b 2 0) :ch) "c")
  (t/assert= ((tui/buffer-get b 3 0) :ch) " ")))  # ⚠ didn't fit

# ── buffer-to-plain-rows skips continuation ───────────────────

(t/test "plain-rows skips continuation cells" (fn []
  (def area (tui/rect 0 0 10 1))
  (def b (tui/buffer area))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (tui/buffer-set-string b 0 0 (string "X" warning "Y") (tui/style))
  (def rows (tui/buffer-to-plain-rows b))
  (def row (get rows 0))
  # Should read "X⚠Y" not "X⚠ Y" (no phantom space from continuation)
  (t/assert= row (string "X" warning "Y"))))

# ── buffer-diff with wide chars ───────────────────────────────

(t/test "buffer-diff positions cursor correctly after wide char" (fn []
  (def area (tui/rect 0 0 20 1))
  (def old (tui/buffer area))
  (def new (tui/buffer area))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (tui/buffer-set-string new 0 0 (string "X" warning "Y") (tui/style))
  (def diff (tui/buffer-diff old new))
  # The diff should emit X at col 1, ⚠ at col 2, Y at col 4 (1-indexed ANSI)
  # Since they're contiguous in cursor movement (X advances 1, ⚠ advances 2),
  # only one cursor-move should be emitted at the start
  (t/assert-truthy (string/find "X" diff))
  (t/assert-truthy (string/find warning diff))
  (t/assert-truthy (string/find "Y" diff))))

# ── span-width with wide chars ────────────────────────────────

(print "── text wide char handling ──")

(t/test "span-width counts display columns not bytes" (fn []
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (def s (text/span (string warning "bc") (tui/style)))
  (t/assert= (text/span-width s) 4)))  # ⚠=2, b=1, c=1

(t/test "line-width with wide chars" (fn []
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (def ln (text/line (text/span (string "A" warning "B") (tui/style))))
  (t/assert= (text/line-width ln) 4)))  # A=1, ⚠=2, B=1

# ── render-line handles UTF-8 properly ────────────────────────

(t/test "render-line preserves multi-byte UTF-8 chars" (fn []
  (def area (tui/rect 0 0 20 1))
  (def b (tui/buffer area))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (def ln (text/line (text/span (string "A" warning "B") (tui/style))))
  (def tw (text/text ln))
  ((tw :render) tw area b)
  (t/assert= ((tui/buffer-get b 0 0) :ch) "A")
  (t/assert= ((tui/buffer-get b 1 0) :ch) warning)
  (t/assert= ((tui/buffer-get b 2 0) :ch) "")     # continuation
  (t/assert= ((tui/buffer-get b 3 0) :ch) "B")))

# ── chat widget wrapping with wide chars ──────────────────────

(print "── chat wide char wrapping ──")

(defn- setup-chat [&opt width height]
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
  (default width 40)
  (default height 10)
  (def bw (+ width 2))
  (def bh (+ height 2))
  (def r (tui/rect 0 0 bw bh))
  (def b (tui/buffer r))
  ((w :render) w r b)
  (def content-rows @[])
  (for row 0 height
    (def chars @[])
    (for col 0 width
      (def cell (tui/buffer-get b (+ col 1) (+ row 1)))
      (def ch (cell :ch))
      (unless (= ch "") (array/push chars ch)))
    (array/push content-rows (string/trimr (string ;chars))))
  content-rows)

(t/test "chat: wide char in agent output renders correctly" (fn []
  (def w (setup-chat 60 6))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (chat/output-agent (string "Test " warning " done"))
  (def rows (render-chat w 60 6))
  (def found (some |(string/find warning $) rows))
  (t/assert-truthy found)))

(t/test "chat: wide char in user message renders correctly" (fn []
  (def w (setup-chat 60 6))
  (def warning (string/from-bytes 0xE2 0x9A 0xA0))
  (chat/output-user (string "Check " warning " this"))
  (def rows (render-chat w 60 6))
  (def found (some |(string/find warning $) rows))
  (t/assert-truthy found)))
