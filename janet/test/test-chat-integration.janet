# test/test-chat-integration.janet — Chat widget integration tests.
#
# Tests the full state machine: submit → streaming → tools → idle.
# Uses fake-http to mock the Anthropic API and fake-api to build SSE responses.

# ── Setup: install mocks before importing anything ─────────────

(import test/fake-http :as fake)
(fake/install (curenv))

(import test/fake-api :as fake-api)
(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/conversation :as conv)
(import core/api :as api)
(import core/tools :as tools)
(import tui)
(import test/helper :as t)

(print "── widgets/chat (integration) ──")

# ── Helpers ────────────────────────────────────────────────────

(defn- setup []
  "Full reset: chat state, widgets, conversation, fake-http queue."
  (chat/reset-state)
  (fake/reset)
  (each name (widget/list-widgets) (widget/unregister name))
  (def w (chat/create))
  (widget/register w)
  (widget/set-layout-fn (fn [a] @{:chat (tui/rect 0 0 80 22)}))
  (widget/do-layout (tui/rect 0 0 80 24))
  (conv/init)
  (api/set-api-key "fake-key-for-testing")
  w)

(defn- tick-until-idle [w &opt max-ticks]
  "Drive the chat event loop until mode returns to :idle."
  (default max-ticks 100)
  (var ticks 0)
  (while (and (chat/active?) (< ticks max-ticks))
    ((w :update) w)
    (++ ticks))
  ticks)

(defn- scrollback-texts []
  "Extract text from all scrollback lines (spans or plain text)."
  (seq [line :in (chat/get-scrollback)]
    (if (line :spans)
      (string ;(map |($ :text) (line :spans)))
      (or (line :text) ""))))

(defn- find-in-scrollback [needle]
  "Return true if any scrollback line contains the needle text."
  (truthy?
    (find |(string/find needle $) (scrollback-texts))))

# ── Text response tests ────────────────────────────────────────

(t/test "submit → text response → idle" (fn []
  (def w (setup))
  (fake/queue-lines (fake-api/text-response "Hello, world!"))

  (chat/submit "Hi there")
  (t/assert= (chat/get-mode) :streaming)

  (tick-until-idle w)
  (t/assert= (chat/get-mode) :idle)

  # User message in scrollback
  (t/assert-truthy (find-in-scrollback "Hi there"))
  # Agent response in scrollback
  (t/assert-truthy (find-in-scrollback "Hello, world!"))))

(t/test "submit → chunked text → idle" (fn []
  (def w (setup))
  (fake/queue-lines (fake-api/text-response-chunked @["Hello, " "world!"]))

  (chat/submit "test chunked")
  (tick-until-idle w)
  (t/assert= (chat/get-mode) :idle)
  (t/assert-truthy (find-in-scrollback "Hello, world!"))))

(t/test "conversation grows after exchange" (fn []
  (def w (setup))
  (fake/queue-lines (fake-api/text-response "Got it."))

  (def before (conv/length))
  (chat/submit "Do something")
  (tick-until-idle w)
  # Should have: user message + assistant message = 2 new
  (t/assert-truthy (>= (conv/length) (+ before 2)))))

# ── Tool call tests ────────────────────────────────────────────

(t/test "submit → tool call → tool result → text → idle" (fn []
  (def w (setup))

  # Register a simple test tool
  (tools/register "test_tool"
    {:description "A test tool"
     :schema {:type "object"
              :properties {:x {:type "string"}}
              :required ["x"]}
     :function (fn [input] (string "result: " (get input :x "?")))})

  # First response: LLM calls the tool
  (fake/queue-lines
    (fake-api/tool-call-response "tool_1" "test_tool" {:x "hello"}))
  # Second response (after tool result): LLM sends text
  (fake/queue-lines
    (fake-api/text-response "Done! The tool returned the result."))

  (chat/submit "Use the test tool")
  (t/assert= (chat/get-mode) :streaming)

  (tick-until-idle w)
  (t/assert= (chat/get-mode) :idle)

  # Should see: user msg, tool call, tool result, agent response
  (t/assert-truthy (find-in-scrollback "Use the test tool"))
  (t/assert-truthy (find-in-scrollback "test_tool"))
  (t/assert-truthy (find-in-scrollback "result: hello"))
  (t/assert-truthy (find-in-scrollback "Done!"))))

(t/test "tool error is handled gracefully" (fn []
  (def w (setup))

  (tools/register "failing_tool"
    {:description "A tool that fails"
     :schema {:type "object" :properties {} :required []}
     :function (fn [input] (error "kaboom!"))})

  (fake/queue-lines
    (fake-api/tool-call-response "tool_2" "failing_tool" {}))
  (fake/queue-lines
    (fake-api/text-response "I see the tool failed."))

  (chat/submit "try the failing tool")
  (tick-until-idle w)
  (t/assert= (chat/get-mode) :idle)

  # Error should appear in scrollback
  (t/assert-truthy (find-in-scrollback "kaboom!"))))

# ── Error handling tests ───────────────────────────────────────

(t/test "API error response → idle with error" (fn []
  (def w (setup))
  (fake/queue-lines (fake-api/error-response "rate_limited"))

  (chat/submit "trigger error")
  (tick-until-idle w)
  (t/assert= (chat/get-mode) :idle)

  # Error should appear in scrollback
  (t/assert-truthy (find-in-scrollback "rate_limited"))))

(t/test "empty stream → idle gracefully" (fn []
  (def w (setup))
  # Queue nothing — stream-read returns :done immediately
  (chat/submit "empty response")
  (tick-until-idle w)
  (t/assert= (chat/get-mode) :idle)))

# ── Stop/interrupt tests ──────────────────────────────────────

(t/test "stop during streaming → idle" (fn []
  (def w (setup))
  # Queue a response but stop before draining
  (fake/queue-lines (fake-api/text-response "This won't finish"))

  (chat/submit "going to stop")
  (t/assert= (chat/get-mode) :streaming)

  (chat/stop)
  (t/assert= (chat/get-mode) :idle)
  (t/assert-truthy (find-in-scrollback "stopped"))))

# ── Scroll after conversation ─────────────────────────────────

(t/test "scroll works after conversation fills scrollback" (fn []
  (def w (setup))

  # Generate enough content to overflow the viewport
  (for i 0 30
    (fake/queue-lines (fake-api/text-response (string "Response line " i)))
    (chat/submit (string "msg " i))
    (tick-until-idle w))

  (def total (length (chat/get-scrollback)))
  (t/assert-truthy (> total 22))

  # Page up
  ((w :handle) w {:type :scroll-up})
  (t/assert-truthy (> (chat/get-scroll-offset) 0))

  # Page down back to bottom
  ((w :handle) w {:type :scroll-down})
  (t/assert= (chat/get-scroll-offset) 0)))

(def pass (t/pass))
(def fail (t/fail))
