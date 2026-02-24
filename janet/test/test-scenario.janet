# test/test-scenario.janet — Tests for the scenario DSL.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/stage :as stage)
(import core/scenario :as sc)
(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/conversation :as conv)
(import tui)
(import test/helper :as t)
(import test/stage-helpers :as sh)

(print "── core/scenario ──")

# ── Reactor driver tests ─────────────────────────────────────

(t/test "tick drives the reactor" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text "tick test" :delay 0))

  (sc/submit "go")
  (t/assert= (chat/get-mode) :streaming)

  (sc/tick 100)
  (t/assert= (chat/get-mode) :idle)))

(t/test "tick-until-idle waits for completion" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text "waiting"))

  (sc/submit "go")
  (def ticks (sc/tick-until-idle))
  (t/assert= (chat/get-mode) :idle)
  (t/assert-truthy (> ticks 0))))

(t/test "tick-until waits for predicate" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text "pred test"))

  (sc/submit "go")
  (def ticks (sc/tick-until |(not (chat/active?))))
  (t/assert= (chat/get-mode) :idle)
  (t/assert-truthy (> ticks 0))))

(t/test "tick-until-idle respects max-ticks" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text-stream "long" :token-delay 999))

  (sc/submit "go")
  (def ticks (sc/tick-until-idle 5))
  (t/assert-truthy (<= ticks 5))))

# ── Action tests ──────────────────────────────────────────────

(t/test "submit sends text to chat" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text "got it"))

  (sc/submit "hello from scenario")
  (sc/tick-until-idle)
  (t/assert-truthy (sc/find-in-scrollback "hello from scenario"))))

(t/test "scroll changes offset" (fn []
  (def w (sh/setup-stage))
  # Fill scrollback with enough content
  (for i 0 30
    (chat/output (string "line " i)))

  (sc/scroll :up 5)
  (t/assert-truthy (> (chat/get-scroll-offset) 0))

  (sc/scroll :down 5)
  (t/assert= (chat/get-scroll-offset) 0)))

(t/test "scroll-page works" (fn []
  (def w (sh/setup-stage))
  (for i 0 50
    (chat/output (string "line " i)))

  (sc/scroll-page :up)
  (t/assert-truthy (> (chat/get-scroll-offset) 0))

  (sc/scroll-page :down)
  (t/assert= (chat/get-scroll-offset) 0)))

# ── Assertion tests ───────────────────────────────────────────

(t/test "assert-mode passes when mode matches" (fn []
  (def w (sh/setup-stage))
  (sc/assert-mode :idle)))

(t/test "assert-mode fails when mode differs" (fn []
  (def w (sh/setup-stage))
  (var caught false)
  (try
    (sc/assert-mode :streaming)
    ([err] (set caught true)))
  (t/assert-truthy caught)))

(t/test "assert-visible finds text" (fn []
  (def w (sh/setup-stage))
  (chat/output "visible text here")
  (sc/assert-visible "visible text")))

(t/test "assert-visible fails when missing" (fn []
  (def w (sh/setup-stage))
  (var caught false)
  (try
    (sc/assert-visible "nonexistent text")
    ([err] (set caught true)))
  (t/assert-truthy caught)))

(t/test "assert-not-visible passes when absent" (fn []
  (def w (sh/setup-stage))
  (sc/assert-not-visible "absent text")))

(t/test "assert-not-visible fails when present" (fn []
  (def w (sh/setup-stage))
  (chat/output "this is present")
  (var caught false)
  (try
    (sc/assert-not-visible "this is present")
    ([err] (set caught true)))
  (t/assert-truthy caught)))

(t/test "assert-scroll-offset checks value" (fn []
  (def w (sh/setup-stage))
  (sc/assert-scroll-offset 0)
  (for i 0 30 (chat/output (string "line " i)))
  (sc/scroll :up 3)
  (sc/assert-scroll-offset 3)))

# ── Screenshot tests ──────────────────────────────────────────

(t/test "screenshot returns plain text rows" (fn []
  (def w (sh/setup-stage))
  (chat/output "screenshot line")
  (def rows (sc/screenshot))
  (t/assert-truthy (> (length rows) 0))
  (t/assert-truthy (find |(string/find "screenshot" $) rows))))

# ── Full stage+scenario integration ──────────────────────────

(t/test "full flow: submit → stream → scroll → assert" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text-stream
    (string/join (seq [i :range [0 30]] (string "line " i)) "\n")
    :token-delay 0))

  (sc/submit "generate lines")
  (sc/tick-until-idle)
  (sc/assert-mode :idle)
  (sc/assert-visible "line 0")
  (sc/assert-visible "line 29")

  (sc/scroll :up 5)
  (t/assert-truthy (> (chat/get-scroll-offset) 0))

  (sc/scroll :down 5)
  (sc/assert-scroll-offset 0)))

(def pass (t/pass))
(def fail (t/fail))
