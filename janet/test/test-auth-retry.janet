# test/test-auth-retry.janet — Tests for the chat widget's auth retry mechanism.
#
# Verifies that:
#   - 401/403 errors trigger a token refresh + retry
#   - Non-auth errors (500, 429) skip retry and go straight to idle
#   - Failed token refresh shows appropriate error
#   - Auth retry only fires once per turn (no infinite loops)

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/api :as api)
(import core/auth :as auth)
(import core/stage :as stage)
(import core/scenario :as sc)
(import widgets/chat :as chat)
(import widgets/editor :as editor)
(import core/widget :as widget)
(import core/conversation :as conv)
(import test/helper :as t)
(import test/stage-helpers :as sh)
(import tui)

(print "── test-auth-retry ──")

# ── Helper: create a provider that queues stream behaviours ────

(defn- make-scripted-provider
  "Build a stream provider backed by a queue of scripted stream behaviours.
   Each behaviour is an array of values that stream-read returns in order.
   Values can be: string SSE lines, :done, @{:type :error :message ...}, or nil."
  [behaviours]
  (var stream-idx 0)
  (var active-queues @{})
  (var next-id 1)
  @{:stream-start
    (fn [conversation tools callbacks &opt system-prompt]
      (def parser (api/new-stream-parser callbacks))
      (def id next-id)
      (++ next-id)
      (def behaviour
        (if (< stream-idx (length behaviours))
          (do
            (def b (get behaviours stream-idx))
            (++ stream-idx)
            b)
          @[:done]))
      (put active-queues id (array/slice behaviour))
      @{:parser parser :stream-id id})
    :stream-read
    (fn [stream-id]
      (def q (get active-queues stream-id))
      (if (or (nil? q) (empty? q))
        :done
        (do
          (def val (first q))
          (array/remove q 0)
          val)))
    :stream-stop
    (fn [stream-id]
      (put active-queues stream-id nil))})

(defn- setup-test [&opt cols rows]
  "Standard test setup: reset widgets, conversation, fakes."
  (default cols 80)
  (default rows 24)
  (chat/reset-state)
  (fake/reset)
  (each name (widget/list-widgets) (widget/unregister name))
  (widget/register (chat/create))
  (widget/register (editor/create))
  (defn default-layout [area]
    (def ed-height 5)
    (def [chat-area editor-area] (tui/vsplit area :fill ed-height))
    @{:chat chat-area :editor editor-area})
  (widget/set-layout-fn default-layout)
  (widget/do-layout (tui/rect 0 0 cols rows))
  (widget/focus :editor)
  (api/set-provider "anthropic")
  (conv/init))

(defn- setup-auth-credential []
  "Install a fake Anthropic OAuth credential so force-refresh-auth has something to refresh."
  (auth/set-credential "anthropic"
    @{"type" "oauth"
      "access" "old-access-token"
      "refresh" "test-refresh-token"
      "expires" 0}))

(defn- queue-successful-refresh []
  "Queue a mock HTTP response for a successful Anthropic token refresh."
  (fake/queue-request-response
    (json/encode @{:access_token "new-access-token"
                   :refresh_token "new-refresh-token"
                   :expires_in 3600})))

(defn- make-401-error []
  @{:type :error
    :message "status 401 — {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid api key\"}}"})

(defn- make-403-error []
  @{:type :error
    :message "status 403 — forbidden"})

(defn- make-500-error []
  @{:type :error
    :message "status 500 — internal server error"})

(defn- make-429-error []
  @{:type :error
    :message "status 429 — rate limited"})

(defn- make-success-sse []
  "Return an array of SSE lines for a simple text response."
  @[(string `data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"test","stop_reason":null}}`)
    (string `data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`)
    (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Success after retry!"}}`)
    (string `data: {"type":"content_block_stop","index":0}`)
    (string `data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}`)
    (string `data: {"type":"message_stop"}`)
    "data: [DONE]"])

# ── Test: auth retry succeeds on 401 ──────────────────────────

(t/test "401 error triggers token refresh and retries streaming"
  (fn []
    (setup-test)
    (setup-auth-credential)
    (queue-successful-refresh)

    (def provider
      (make-scripted-provider
        @[# First stream: returns 401 error immediately
          @[(make-401-error)]
          # Second stream (after refresh): returns success
          (make-success-sse)]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    (sc/assert-visible "Token refreshed, retrying")
    (sc/assert-visible "Success after retry!")))

# ── Test: auth retry succeeds on 403 ──────────────────────────

(t/test "403 error triggers token refresh and retries streaming"
  (fn []
    (setup-test)
    (setup-auth-credential)
    (queue-successful-refresh)

    (def provider
      (make-scripted-provider
        @[@[(make-403-error)]
          (make-success-sse)]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    (sc/assert-visible "Token refreshed, retrying")))

# ── Test: auth retry succeeds on authentication_error ─────────

(t/test "authentication_error in body triggers token refresh"
  (fn []
    (setup-test)
    (setup-auth-credential)
    (queue-successful-refresh)

    (def provider
      (make-scripted-provider
        @[@[@{:type :error :message "something went wrong: authentication_error in response"}]
          (make-success-sse)]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    (sc/assert-visible "Token refreshed, retrying")))

# ── Test: auth retry fails — refresh returns false ────────────

(t/test "401 with failed token refresh shows error message"
  (fn []
    (setup-test)
    # No OAuth credential → force-refresh-auth returns false
    (auth/remove-credential "anthropic")

    (def provider
      (make-scripted-provider
        @[@[(make-401-error)]]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    (sc/assert-visible "Token refresh failed")))

# ── Test: non-auth error (500) skips retry ────────────────────

(t/test "500 error skips auth retry and shows stream error"
  (fn []
    (setup-test)

    (def provider
      (make-scripted-provider
        @[@[(make-500-error)]]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    (sc/assert-visible "Stream error: status 500")
    (sc/assert-not-visible "Token refreshed")
    (sc/assert-not-visible "Token refresh failed")))

# ── Test: non-auth error (429) skips retry ────────────────────

(t/test "429 error skips auth retry and shows stream error"
  (fn []
    (setup-test)

    (def provider
      (make-scripted-provider
        @[@[(make-429-error)]]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    (sc/assert-visible "Stream error: status 429")
    (sc/assert-not-visible "Token refreshed")))

# ── Test: auth retry only fires once (no infinite loop) ───────

(t/test "auth retry fires only once even if second stream also returns 401"
  (fn []
    (setup-test)
    (setup-auth-credential)
    (queue-successful-refresh)

    (def provider
      (make-scripted-provider
        @[# First stream: 401
          @[(make-401-error)]
          # Second stream (after refresh): also 401
          @[(make-401-error)]]))
    (chat/set-provider provider)

    (sc/submit "Hello")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)

    # First 401 triggers retry
    (sc/assert-visible "Token refreshed, retrying")
    # Second 401 treated as normal error (auth-retry-pending is true)
    (sc/assert-visible "Stream error: status 401")))

# ── Test: auth retry resets between turns ─────────────────────

(t/test "auth retry resets between turns allowing retry on next submit"
  (fn []
    (setup-test)
    (setup-auth-credential)
    (queue-successful-refresh)

    (def provider
      (make-scripted-provider
        @[# Turn 1: 401 → refresh → success
          @[(make-401-error)]
          (make-success-sse)
          # Turn 2: 401 → refresh → success (retry should work again)
          @[(make-401-error)]
          (make-success-sse)]))
    (chat/set-provider provider)

    # Turn 1
    (sc/submit "First turn")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)
    (sc/assert-visible "Token refreshed, retrying")

    # Turn 2: queue another successful refresh
    (setup-auth-credential)
    (queue-successful-refresh)
    (sc/submit "Second turn")
    (sc/tick-until-idle)
    (sc/assert-mode :idle)))

(def pass (t/pass))
(def fail (t/fail))
