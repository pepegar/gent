# Tests for tui/text
(use tui/rect)
(use tui/style)
(use tui/buffer)
(use tui/text)
(import test/helper :as t)

(print "── tui/text ──")

(t/test "span creates with text and style" (fn []
                                            (def s (span "hello" (style :fg :red)))
                                            (t/assert= (s :text) "hello")
                                            (t/assert= ((s :style) :fg) :red)))

(t/test "span-width" (fn []
                      (t/assert= (span-width (span "hello")) 5)
                      (t/assert= (span-width (span "")) 0)))

(t/test "line creates from spans" (fn []
                                   (def l (line (span "a") (span "b")))
                                   (t/assert= (length (l :spans)) 2)))

(t/test "line-width sums spans" (fn []
                                 (def l (line (span "hello") (span " world")))
                                 (t/assert= (line-width l) 11)))

(t/test "text widget renders into buffer" (fn []
                                           (def t-widget (text "Hi" :style (style :fg :green)))
                                           (def area (rect 0 0 10 3))
                                           (def buf (buffer area))
                                           ((t-widget :render) t-widget area buf)
                                           (t/assert= ((buffer-get buf 0 0) :ch) "H")
                                           (t/assert= ((buffer-get buf 1 0) :ch) "i")))

(t/test "text multi-line" (fn []
                           (def t-widget (text "Line1\nLine2"))
                           (def area (rect 0 0 10 3))
                           (def buf (buffer area))
                           ((t-widget :render) t-widget area buf)
                           (t/assert= ((buffer-get buf 0 0) :ch) "L")
                           (t/assert= ((buffer-get buf 0 1) :ch) "L")))

(t/test "span->str" (fn []
                     (def s (span "ok"))
                     (t/assert= (span->str s) "ok")))

(t/test "span->str with style" (fn []
                                (def s (span "ok" (style :fg :red)))
                                (def result (span->str s))
                                (t/assert-truthy (string/find "31" result))
                                (t/assert-truthy (string/find "ok" result))))

(def pass (t/pass))
(def fail (t/fail))
