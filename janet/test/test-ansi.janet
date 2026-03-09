# test/test-ansi.janet — Tests for ANSI escape code parsing.

(import test/helper :as t)
(import tui/style :as style)
(import tui/ansi :as ansi)

(t/test "plain text returns single span" (fn []
  (def spans (ansi/ansi->spans "hello world"))
  (t/assert= 1 (length spans))
  (t/assert= "hello world" ((first spans) :text))))

(t/test "basic foreground color" (fn []
  (def spans (ansi/ansi->spans "\x1b[31mred text\x1b[0m normal"))
  (t/assert= 2 (length spans))
  (t/assert= "red text" ((get spans 0) :text))
  (t/assert= :red (get ((get spans 0) :style) :fg))
  # After reset
  (t/assert= " normal" ((get spans 1) :text))
  (t/assert= nil (get ((get spans 1) :style) :fg))))

(t/test "multiple colors" (fn []
  (def spans (ansi/ansi->spans "\x1b[35m16:38\x1b[0;39m \x1b[34mINFO\x1b[0m rest"))
  (t/assert= :magenta (get ((get spans 0) :style) :fg))
  (t/assert= "16:38" ((get spans 0) :text))
  (t/assert= " " ((get spans 1) :text))
  (t/assert= :blue (get ((get spans 2) :style) :fg))
  (t/assert= "INFO" ((get spans 2) :text))))

(t/test "24-bit RGB colors" (fn []
  (def spans (ansi/ansi->spans "\x1b[38;2;255;128;0mhello\x1b[0m"))
  (t/assert= "hello" ((get spans 0) :text))
  (def fg (get ((get spans 0) :style) :fg))
  (t/assert= :rgb (get fg 0))
  (t/assert= 255 (get fg 1))
  (t/assert= 128 (get fg 2))
  (t/assert= 0 (get fg 3))))

(t/test "256-color indexed" (fn []
  (def spans (ansi/ansi->spans "\x1b[38;5;196mhello\x1b[0m"))
  (t/assert= "hello" ((get spans 0) :text))
  (def fg (get ((get spans 0) :style) :fg))
  (t/assert= :indexed (get fg 0))
  (t/assert= 196 (get fg 1))))

(t/test "bold and underline" (fn []
  (def spans (ansi/ansi->spans "\x1b[1;4mbold underline\x1b[0m"))
  (t/assert= "bold underline" ((get spans 0) :text))
  (t/assert-truthy (get ((get spans 0) :style) :bold))
  (t/assert-truthy (get ((get spans 0) :style) :underline))))

(t/test "background color" (fn []
  (def spans (ansi/ansi->spans "\x1b[41mred bg\x1b[0m"))
  (t/assert= "red bg" ((get spans 0) :text))
  (t/assert= :red (get ((get spans 0) :style) :bg))))

(t/test "bright colors" (fn []
  (def spans (ansi/ansi->spans "\x1b[91mbright red\x1b[0m"))
  (t/assert= "bright red" ((get spans 0) :text))
  (t/assert= :bright-red (get ((get spans 0) :style) :fg))))

(t/test "strip-ansi removes all codes" (fn []
  (def result (ansi/strip-ansi "\x1b[35m16:38\x1b[0;39m \x1b[34mINFO\x1b[0m rest"))
  (t/assert= "16:38 INFO rest" result)))

(t/test "empty ESC[m is reset" (fn []
  (def spans (ansi/ansi->spans "\x1b[31mred\x1b[mnormal"))
  (t/assert= :red (get ((get spans 0) :style) :fg))
  (t/assert= "normal" ((get spans 1) :text))
  # After reset, fg should be nil
  (t/assert= nil (get ((get spans 1) :style) :fg))))

(t/test "combined reset: 0;39m" (fn []
  (def spans (ansi/ansi->spans "\x1b[35mtext\x1b[0;39m rest"))
  (t/assert= :magenta (get ((get spans 0) :style) :fg))
  (t/assert= " rest" ((get spans 1) :text))
  (t/assert= nil (get ((get spans 1) :style) :fg))))

(t/test "real gradle output line" (fn []
  (def line "\x1b[35m16:38:14.866\x1b[0;39m \x1b[34mINFO \x1b[0;39m \x1b[33m        c.z.h.HikariDataSource\x1b[0;39m \x1b[35m-\x1b[0;39m HikariPool-1 - Shutdown initiated...")
  (def spans (ansi/ansi->spans line))
  (t/assert-truthy (> (length spans) 1))
  # First span should be magenta timestamp
  (t/assert= :magenta (get ((get spans 0) :style) :fg))
  (t/assert= "16:38:14.866" ((get spans 0) :text))
  # Verify strip produces clean text
  (def stripped (ansi/strip-ansi line))
  (t/assert= "16:38:14.866 INFO          c.z.h.HikariDataSource - HikariPool-1 - Shutdown initiated..." stripped)))

(t/test "ansi->spans with base style" (fn []
  (def base (style/style :fg :white))
  (def spans (ansi/ansi->spans "hello \x1b[31mred\x1b[0m world" base))
  # "hello " should have base style (white fg)
  (t/assert= :white (get ((get spans 0) :style) :fg))
  (t/assert= "hello " ((get spans 0) :text))
  # "red" should have red fg
  (t/assert= :red (get ((get spans 1) :style) :fg))
  # " world" after reset — should have default style, not base
  (t/assert= " world" ((get spans 2) :text))))
