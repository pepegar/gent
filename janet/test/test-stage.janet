# test/test-stage.janet — Tests for the stage provider.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/stage :as stage)
(import core/api :as api)
(import core/tools :as tools)
(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/conversation :as conv)
(import tui)
(import test/helper :as t)
(import test/stage-helpers :as sh)

(print "── core/stage ──")

# ── Response generator tests ──────────────────────────────────

(t/test "text generator creates valid SSE lines" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text "Hello stage!"))

  (chat/submit "test")
  (var ticks 0)
  (while (and (chat/active?) (< ticks 100))
    ((w :update) w)
    (++ ticks))
  (t/assert= (chat/get-mode) :idle)

  (def texts (seq [line :in (chat/get-scrollback)]
    (if (line :spans)
      (string ;(map |($ :text) (line :spans)))
      (or (line :text) ""))))
  (t/assert-truthy (find |(string/find "Hello stage!" $) texts))))

(t/test "text-stream generator streams token-by-token" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text-stream "ABC" :token-delay 0))

  (chat/submit "test stream")
  (var ticks 0)
  (while (and (chat/active?) (< ticks 100))
    ((w :update) w)
    (++ ticks))
  (t/assert= (chat/get-mode) :idle)

  (def texts (seq [line :in (chat/get-scrollback)]
    (if (line :spans)
      (string ;(map |($ :text) (line :spans)))
      (or (line :text) ""))))
  (t/assert-truthy (find |(string/find "ABC" $) texts))))

(t/test "tool-call generator produces tool_use response" (fn []
  (def w (sh/setup-stage))

  (import core/tools :as tools)
  (tools/register "stage_test_tool"
    {:description "test"
     :schema {:type "object" :properties {:x {:type "string"}} :required ["x"]}
     :function (fn [input] (string "got: " (get input :x "?")))})

  (stage/respond (stage/tool-call "stage_test_tool" {:x "hello"}))
  (stage/respond (stage/text "Tool done."))

  (chat/submit "use the tool")
  (var ticks 0)
  (while (and (chat/active?) (< ticks 200))
    ((w :update) w)
    (++ ticks))
  (t/assert= (chat/get-mode) :idle)

  (def texts (seq [line :in (chat/get-scrollback)]
    (if (line :spans)
      (string ;(map |($ :text) (line :spans)))
      (or (line :text) ""))))
  (t/assert-truthy (find |(string/find "got: hello" $) texts))
  (t/assert-truthy (find |(string/find "Tool done." $) texts))))

(t/test "queue: multiple responses served in FIFO order" (fn []
  (def w (sh/setup-stage))
  (stage/respond (stage/text "First"))
  (stage/respond (stage/text "Second"))
  (t/assert= (stage/queue-length) 2)

  (chat/submit "msg1")
  (var ticks 0)
  (while (and (chat/active?) (< ticks 100))
    ((w :update) w)
    (++ ticks))
  (t/assert= (chat/get-mode) :idle)
  (t/assert= (stage/queue-length) 1)

  (chat/submit "msg2")
  (set ticks 0)
  (while (and (chat/active?) (< ticks 100))
    ((w :update) w)
    (++ ticks))
  (t/assert= (chat/get-mode) :idle)
  (t/assert= (stage/queue-length) 0)))

(t/test "empty queue returns default message" (fn []
  (def w (sh/setup-stage))

  (chat/submit "nothing queued")
  (var ticks 0)
  (while (and (chat/active?) (< ticks 100))
    ((w :update) w)
    (++ ticks))
  (t/assert= (chat/get-mode) :idle)

  (def texts (seq [line :in (chat/get-scrollback)]
    (if (line :spans)
      (string ;(map |($ :text) (line :spans)))
      (or (line :text) ""))))
  (t/assert-truthy (find |(string/find "no response queued" $) texts))))

(t/test "reset clears queue and state" (fn []
  (stage/respond (stage/text "will be cleared"))
  (t/assert= (stage/queue-length) 1)
  (stage/reset)
  (t/assert= (stage/queue-length) 0)))

(t/test "sequence queues multiple responses" (fn []
  (stage/reset)
  (stage/sequence [(stage/text "A") (stage/text "B") (stage/text "C")])
  (t/assert= (stage/queue-length) 3)
  (stage/reset)))

(def pass (t/pass))
(def fail (t/fail))
