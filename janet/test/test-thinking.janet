# test/test-thinking.janet — Tests for thinking block support.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/api :as api)
(import core/stage :as stage)
(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/conversation :as conv)
(import core/scenario :as sc)
(import test/helper :as t)
(import test/fake-api :as fake-api)
(import test/stage-helpers :as sh)

(print "── thinking blocks ──")

# ── SSE parser tests ──────────────────────────────────────────

(t/test "parser accumulates thinking blocks" (fn []
                                              (var thinking-text @"")
                                              (def parser (api/new-stream-parser
                                                           @{:on-thinking (fn [text] (buffer/push thinking-text text))}))
                                              (each line (fake-api/thinking-response "Let me think about this")
                                                ((parser :feed) line))
                                              (def response ((parser :finish)))
                                              (def content (response :content))
                                              (t/assert= (length content) 1)
                                              (t/assert= ((first content) :type) "thinking")
                                              (t/assert= ((first content) :thinking) "Let me think about this")
                                              (t/assert= (string thinking-text) "Let me think about this")))

(t/test "parser handles thinking then text" (fn []
                                             (var thinking-text @"")
                                             (var text-text @"")
                                             (def parser (api/new-stream-parser
                                                          @{:on-thinking (fn [text] (buffer/push thinking-text text))
                                                            :on-text (fn [text] (buffer/push text-text text))}))
                                             (each line (fake-api/thinking-then-text-response "I need to think" "The answer is 4")
                                               ((parser :feed) line))
                                             (def response ((parser :finish)))
                                             (def content (response :content))
                                             (t/assert= (length content) 2)
                                             (t/assert= ((get content 0) :type) "thinking")
                                             (t/assert= ((get content 0) :thinking) "I need to think")
                                             (t/assert= ((get content 1) :type) "text")
                                             (t/assert= ((get content 1) :text) "The answer is 4")
                                             (t/assert= (string thinking-text) "I need to think")
                                             (t/assert= (string text-text) "The answer is 4")))

(t/test "parser handles signature_delta" (fn []
                                          (def parser (api/new-stream-parser @{}))
                                          (def lines
                                            @[(string `data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"test","stop_reason":null}}`)
                                              (string `data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}`)
                                              (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hello"}}`)
                                              (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}`)
                                              (string `data: {"type":"content_block_stop","index":0}`)
                                              (string `data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}`)
                                              (string `data: {"type":"message_stop"}`)
                                              "data: [DONE]"])
                                          (each line lines ((parser :feed) line))
                                          (def response ((parser :finish)))
                                          (def block (first (response :content)))
                                          (t/assert= (block :type) "thinking")
                                          (t/assert= (block :thinking) "hello")
                                          (t/assert= (block :signature) "sig123")))

(t/test "parser without on-thinking callback still accumulates" (fn []
                                                                 (def parser (api/new-stream-parser @{}))
                                                                 (each line (fake-api/thinking-response "silent thinking")
                                                                   ((parser :feed) line))
                                                                 (def response ((parser :finish)))
                                                                 (t/assert= (length (response :content)) 1)
                                                                 (t/assert= ((first (response :content)) :thinking) "silent thinking")))

# ── Stage provider tests ──────────────────────────────────────

(t/test "stage thinking-then-text generates correct SSE" (fn []
                                                          (def w (sh/setup-stage))
                                                          (stage/respond (stage/thinking-then-text "deep thought" "42"))
                                                          (sc/submit "go")
                                                          (sc/tick-until-idle)
                                                          (t/assert= (chat/get-mode) :idle)
                                                          (def msgs (conv/get-messages))
                                                          (def last-msg (last msgs))
                                                          (t/assert= (last-msg :role) "assistant")
                                                          (def content (last-msg :content))
                                                          (t/assert= (length content) 2)
                                                          (t/assert= ((get content 0) :type) "thinking")
                                                          (t/assert= ((get content 0) :thinking) "deep thought")
                                                          (t/assert= ((get content 1) :type) "text")
                                                          (t/assert= ((get content 1) :text) "42")))

# ── Chat widget thinking display tests ──────────────────────

(t/test "thinking shows collapsed block in scrollback" (fn []
                                                        (def w (sh/setup-stage))
                                                        (stage/respond (stage/thinking-then-text "my thinking" "result"))
                                                        (sc/submit "test")
                                                        (sc/tick-until-idle)
                                                        (t/assert-truthy (sc/find-in-scrollback "think:"))))

(t/test "thinking text appears in scrollback" (fn []
                                               (def w (sh/setup-stage))
                                               (stage/respond (stage/thinking-then-text "my thinking" "result text"))
                                               (sc/submit "test")
                                               (sc/tick-until-idle)
                                               (t/assert-truthy (sc/find-in-scrollback "result text"))))

(t/test "toggle-thinking expands collapsed blocks" (fn []
                                                    (def w (sh/setup-stage))
                                                    (stage/respond (stage/thinking-then-text "expanded thinking content" "result"))
                                                    (sc/submit "test")
                                                    (sc/tick-until-idle)
                                                    (widget/dispatch :chat {:type :toggle-thinking})
                                                    (t/assert-truthy (sc/find-in-scrollback "expanded thinking content"))))

(t/test "toggle-thinking twice collapses back" (fn []
                                                (def w (sh/setup-stage))
                                                (stage/respond (stage/thinking-then-text "hidden thinking" "result"))
                                                (sc/submit "test")
                                                (sc/tick-until-idle)
                                                (widget/dispatch :chat {:type :toggle-thinking})
                                                (t/assert-truthy (sc/find-in-scrollback "hidden thinking"))
                                                (widget/dispatch :chat {:type :toggle-thinking})
                                                (t/assert-truthy (sc/find-in-scrollback "think:"))))

(def pass (t/pass))
(def fail (t/fail))
