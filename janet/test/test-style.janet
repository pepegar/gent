# Tests for tui/style
(use tui/style)
(import test/helper :as t)

(print "── tui/style ──")

(t/test "style-default is empty" (fn []
                                  (t/assert= (style->sgr style-default) "")
                                  (t/assert= (style-default :_sgr) "")))

(t/test "style creates struct" (fn []
                                (def s (style :fg :red :bold true))
                                (t/assert= (s :fg) :red)
                                (t/assert= (s :bold) true)))

(t/test "style->sgr basic colors" (fn []
                                   (def s (style :fg :red))
                                   (t/assert= (style->sgr s) "\x1b[31m")))

(t/test "style->sgr bold" (fn []
                           (def s (style :bold true))
                           (t/assert= (style->sgr s) "\x1b[1m")))

(t/test "style->sgr combined" (fn []
                               (def s (style :fg :green :bold true))
                               (def sgr (style->sgr s))
  # Should contain both codes
                               (t/assert-truthy (string/find "32" sgr))
                               (t/assert-truthy (string/find "1" sgr))))

(t/test "style->sgr rgb" (fn []
                          (def s (style :fg (rgb 255 0 128)))
                          (def sgr (style->sgr s))
                          (t/assert-truthy (string/find "38;2;255;0;128" sgr))))

(t/test "style->sgr indexed" (fn []
                              (def s (style :fg (color-indexed 240)))
                              (def sgr (style->sgr s))
                              (t/assert-truthy (string/find "38;5;240" sgr))))

(t/test "style-merge overrides" (fn []
                                 (def a (style :fg :red :bold true))
                                 (def b (style :fg :blue :italic true))
                                 (def m (style-merge a b))
                                 (t/assert= (m :fg) :blue)
                                 (t/assert= (m :bold) true)
                                 (t/assert= (m :italic) true)))

(t/test "style-merge nil values don't override" (fn []
                                                 (def a (style :fg :red))
                                                 (def b (style :bold true))
                                                 (def m (style-merge a b))
                                                 (t/assert= (m :fg) :red)
                                                 (t/assert= (m :bold) true)))

(def pass (t/pass))
(def fail (t/fail))
