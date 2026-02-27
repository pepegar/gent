# test/test-chat-integration.janet — Chat widget integration tests.
#
# Tests the full state machine: submit → streaming → tools → idle.
# Uses stage mode for scripted responses and the scenario DSL for actions/assertions.

# ── Setup: install mocks before importing anything ─────────────

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/stage :as stage)
(import core/scenario :as sc)
(import widgets/chat :as chat)
(import core/conversation :as conv)
(import core/tools :as tools)
(import test/helper :as t)
(import test/stage-helpers :as sh)

(print "── widgets/chat (integration) ──")

# ── Text response tests ────────────────────────────────────────

(t/test "submit → text response → idle" (fn []
                                         (sh/setup-stage)
                                         (stage/respond (stage/text "Hello, world!"))

                                         (sc/submit "Hi there")
                                         (t/assert= (chat/get-mode) :streaming)

                                         (sc/tick-until-idle)
                                         (sc/assert-mode :idle)

                                         (sc/assert-visible "Hi there")
                                         (sc/assert-visible "Hello, world!")))

(t/test "submit → chunked text → idle" (fn []
                                        (sh/setup-stage)
                                        (stage/respond (stage/text-stream "Hello, world!" :token-delay 0))

                                        (sc/submit "test chunked")
                                        (sc/tick-until-idle)
                                        (sc/assert-mode :idle)
                                        (sc/assert-visible "Hello, world!")))

(t/test "conversation grows after exchange" (fn []
                                             (sh/setup-stage)
                                             (stage/respond (stage/text "Got it."))

                                             (def before (conv/length))
                                             (sc/submit "Do something")
                                             (sc/tick-until-idle)
                                             (t/assert-truthy (>= (conv/length) (+ before 2)))))

# ── Tool call tests ────────────────────────────────────────────

(t/test "submit → tool call → tool result → text → idle" (fn []
                                                          (sh/setup-stage)

                                                          (tools/register "test_tool"
                                                            {:description "A test tool"
                                                             :schema {:type "object"
                                                                      :properties {:x {:type "string"}}
                                                                      :required ["x"]}
                                                             :function (fn [input] (string "result: " (get input :x "?")))})

                                                          (stage/respond (stage/tool-call "test_tool" {:x "hello"} :id "tool_1"))
                                                          (stage/respond (stage/text "Done! The tool returned the result."))

                                                          (sc/submit "Use the test tool")
                                                          (t/assert= (chat/get-mode) :streaming)

                                                          (sc/tick-until-idle)
                                                          (sc/assert-mode :idle)

                                                          (sc/assert-visible "Use the test tool")
                                                          (sc/assert-visible "test_tool")
                                                          (sc/assert-visible "result: hello")
                                                          (sc/assert-visible "Done!")))

(t/test "tool error is handled gracefully" (fn []
                                            (sh/setup-stage)

                                            (tools/register "failing_tool"
                                              {:description "A tool that fails"
                                               :schema {:type "object" :properties {} :required []}
                                               :function (fn [input] (error "kaboom!"))})

                                            (stage/respond (stage/tool-call "failing_tool" {} :id "tool_2"))
                                            (stage/respond (stage/text "I see the tool failed."))

                                            (sc/submit "try the failing tool")
                                            (sc/tick-until-idle)
                                            (sc/assert-mode :idle)

                                            (sc/assert-visible "kaboom!")))

# ── Error handling tests ───────────────────────────────────────

(t/test "API error response → idle with error" (fn []
                                                (sh/setup-stage)
                                                (stage/respond (stage/error "rate_limited"))

                                                (sc/submit "trigger error")
                                                (sc/tick-until-idle)
                                                (sc/assert-mode :idle)

                                                (sc/assert-visible "rate_limited")))

(t/test "empty stream → idle gracefully" (fn []
                                          (sh/setup-stage)
                                          (sc/submit "empty response")
                                          (sc/tick-until-idle)
                                          (sc/assert-mode :idle)))

# ── Stop/interrupt tests ──────────────────────────────────────

(t/test "stop during streaming → idle" (fn []
                                        (sh/setup-stage)
                                        (stage/respond (stage/text-stream "This won't finish" :token-delay 999))

                                        (sc/submit "going to stop")
                                        (t/assert= (chat/get-mode) :streaming)

                                        (chat/stop)
                                        (t/assert= (chat/get-mode) :idle)
                                        (sc/assert-visible "stopped")))

# ── Scroll after conversation ─────────────────────────────────

(t/test "scroll works after conversation fills scrollback" (fn []
                                                            (sh/setup-stage)

                                                            (for i 0 30
                                                              (stage/respond (stage/text (string "Response line " i)))
                                                              (sc/submit (string "msg " i))
                                                              (sc/tick-until-idle))

                                                            (def total (length (chat/get-scrollback)))
                                                            (t/assert-truthy (> total 22))

                                                            (sc/scroll-page :up)
                                                            (t/assert-truthy (> (chat/get-scroll-offset) 0))

                                                            (sc/scroll-page :down)
                                                            (sc/assert-scroll-offset 0)))

(def pass (t/pass))
(def fail (t/fail))
