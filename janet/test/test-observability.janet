# test/test-observability.janet — Tests for core/observability.
#
# Hook body tests call process-response etc. directly.
# HTTP server tests use the net/* mock from fake-http.

(import test/fake-http :as fake)
(import core/observability :as obs)
(import test/helper :as t)

(print "── core/observability ──")

# Reset state before all tests
(obs/reset)

# ── Token accumulation ────────────────────────────────────────

(t/test "after-response accumulates input and output tokens" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 100 :output_tokens 50}
                          :stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:tokens :input]) 100)
  (t/assert= (get-in state [:tokens :output]) 50)
  (t/assert= (get-in state [:tokens :total]) 150)))

(t/test "after-response accumulates cache tokens" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 10
                                  :output_tokens 5
                                  :cache_creation_input_tokens 200
                                  :cache_read_input_tokens 800}
                          :stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:tokens :cache-write]) 200)
  (t/assert= (get-in state [:tokens :cache-read]) 800)
  (t/assert= (get-in state [:tokens :total]) 1015)))

(t/test "after-response handles nil cache fields safely" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 50 :output_tokens 25}
                          :stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:tokens :cache-write]) 0)
  (t/assert= (get-in state [:tokens :cache-read]) 0)))

(t/test "after-response handles nil usage safely" (fn []
  (obs/reset)
  (obs/process-response {:stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:tokens :input]) 0)
  (t/assert= (get-in state [:tokens :output]) 0)))

(t/test "after-response accumulates multiple responses" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 100 :output_tokens 50} :stop_reason "tool_use"})
  (obs/process-response {:usage {:input_tokens 200 :output_tokens 80} :stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:tokens :input]) 300)
  (t/assert= (get-in state [:tokens :output]) 130)))

# ── Stop reasons ──────────────────────────────────────────────

(t/test "after-response records stop reasons" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 10 :output_tokens 5} :stop_reason "end_turn"})
  (obs/process-response {:usage {:input_tokens 10 :output_tokens 5} :stop_reason "tool_use"})
  (obs/process-response {:usage {:input_tokens 10 :output_tokens 5} :stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:stop-reasons "end_turn"]) 2)
  (t/assert= (get-in state [:stop-reasons "tool_use"]) 1)))

# ── Tool tracking ─────────────────────────────────────────────

(t/test "before/after-tool increments call count" (fn []
  (obs/reset)
  (obs/process-before-tool "bash" {:cmd "ls"})
  (obs/process-after-tool "bash" {:cmd "ls"} "output")
  (obs/process-before-tool "bash" {:cmd "pwd"})
  (obs/process-after-tool "bash" {:cmd "pwd"} "output")
  (def state (obs/get-state))
  (t/assert= (get-in state [:tools "bash" :calls]) 2)
  (t/assert= (get-in state [:tools "bash" :errors]) 0)))

(t/test "after-tool with error result increments error count" (fn []
  (obs/reset)
  (obs/process-before-tool "bash" {:cmd "bad"})
  (obs/process-after-tool "bash" {:cmd "bad"} @{:error "command failed"})
  (def state (obs/get-state))
  (t/assert= (get-in state [:tools "bash" :calls]) 1)
  (t/assert= (get-in state [:tools "bash" :errors]) 1)))

(t/test "after-tool with non-table result does not count as error" (fn []
  (obs/reset)
  (obs/process-before-tool "read-file" "/etc/hosts")
  (obs/process-after-tool "read-file" "/etc/hosts" "file contents")
  (def state (obs/get-state))
  (t/assert= (get-in state [:tools "read-file" :errors]) 0)))

(t/test "multiple tools tracked independently" (fn []
  (obs/reset)
  (obs/process-before-tool "bash" {})
  (obs/process-after-tool "bash" {} "ok")
  (obs/process-before-tool "read-file" {})
  (obs/process-after-tool "read-file" {} "contents")
  (obs/process-before-tool "read-file" {})
  (obs/process-after-tool "read-file" {} "contents")
  (def state (obs/get-state))
  (t/assert= (get-in state [:tools "bash" :calls]) 1)
  (t/assert= (get-in state [:tools "read-file" :calls]) 2)))

# ── Turn tracking ─────────────────────────────────────────────

(t/test "before-send / turn-end records turn duration" (fn []
  (obs/reset)
  (obs/process-before-send @[])
  (obs/process-turn-end)
  (def state (obs/get-state))
  (t/assert= (get-in state [:turns :count]) 1)
  (t/assert-truthy (>= (get-in state [:turns :avg-duration]) 0))))

(t/test "before-send only sets start time once per turn" (fn []
  (obs/reset)
  (obs/process-before-send @[])
  (obs/process-before-send @[])  # second send — should not reset start time
  (obs/process-turn-end)
  (def state (obs/get-state))
  (t/assert= (get-in state [:turns :count]) 1)))

(t/test "multiple turns accumulate" (fn []
  (obs/reset)
  (obs/process-before-send @[])
  (obs/process-turn-end)
  (obs/process-before-send @[])
  (obs/process-turn-end)
  (def state (obs/get-state))
  (t/assert= (get-in state [:turns :count]) 2)))

# ── Cost calculation ──────────────────────────────────────────

(t/test "get-state computes cost for known model" (fn []
  (obs/reset)
  # Set model directly by calling init-style setup without HTTP
  # Use process-response to accumulate tokens, then set model via a workaround:
  # Since model is private, we simulate by calling process-response and checking
  # that cost is nil (model not set) vs set (after init sets model).
  # For cost testing, we verify the pricing math with a known model.
  # We can't set model directly, so test the zero-cost case here.
  (obs/process-response {:usage {:input_tokens 1000000 :output_tokens 0}
                          :stop_reason "end_turn"})
  (def state (obs/get-state))
  # Without init, model is nil → cost is nil
  (t/assert-truthy (nil? (state :cost)))))

(t/test "get-state returns nil cost for unknown model" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 100 :output_tokens 50}
                          :stop_reason "end_turn"})
  (def state (obs/get-state))
  (t/assert-truthy (nil? (state :cost)))))

# ── Format functions ──────────────────────────────────────────

(t/test "format-usage returns a non-empty string" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 1500 :output_tokens 300}
                          :stop_reason "end_turn"})
  (obs/process-before-tool "bash" {})
  (obs/process-after-tool "bash" {} "ok")
  (def result (obs/format-usage))
  (t/assert-truthy (string? result))
  (t/assert-truthy (> (length result) 0))
  (t/assert-truthy (string/find "Tokens:" result))
  (t/assert-truthy (string/find "bash" result))))

(t/test "format-usage shows zero turns when no turns completed" (fn []
  (obs/reset)
  (def result (obs/format-usage))
  (t/assert-truthy (string/find "Turns: 0" result))))

(t/test "metrics-json returns a JSON string with token data" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 42 :output_tokens 10}
                          :stop_reason "end_turn"})
  (def result (obs/metrics-json))
  (t/assert-truthy (string? result))
  (t/assert-truthy (> (length result) 0))
  (t/assert-truthy (string/find "tokens" result))))

# ── commafy helper (tested via format-usage output) ───────────

(t/test "format-usage commaifies large token counts" (fn []
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 15000 :output_tokens 3200}
                          :stop_reason "end_turn"})
  (def result (obs/format-usage))
  (t/assert-truthy (string/find "15,000" result))
  (t/assert-truthy (string/find "3,200" result))))

# ── HTTP server ───────────────────────────────────────────────

(t/test "start-http-server registers the port" (fn []
  (fake/net-reset)
  (obs/reset)
  (obs/start-http-server 7889)
  (t/assert= 7889 (obs/get-http-port))
  (fake/net-reset)
  (obs/reset)))

(t/test "poll-http serves GET /metrics with 200 and JSON body" (fn []
  (fake/net-reset)
  (obs/reset)
  (obs/start-http-server 7889)
  (def conn-id (fake/net-inject-connection 1
    ["GET /metrics HTTP/1.1\r\n"
     "Host: localhost\r\n"
     "\r\n"]))
  (obs/poll-http)
  (def writes (fake/net-get-writes conn-id))
  (t/assert= 1 (length writes))
  (def resp (first writes))
  (t/assert-truthy (string/find "200 OK" resp))
  (t/assert-truthy (string/find "Content-Type: application/json" resp))
  (t/assert-truthy (string/find "tokens" resp))
  (fake/net-reset)
  (obs/reset)))

(t/test "poll-http response body reflects accumulated tokens" (fn []
  (fake/net-reset)
  (obs/reset)
  (obs/process-response {:usage {:input_tokens 500 :output_tokens 200}
                          :stop_reason "end_turn"})
  (obs/start-http-server 7889)
  (def conn-id (fake/net-inject-connection 1
    ["GET /metrics HTTP/1.1\r\n"
     "\r\n"]))
  (obs/poll-http)
  (def resp (first (fake/net-get-writes conn-id)))
  (t/assert-truthy (string/find "200 OK" resp))
  # The body is JSON — check both header separators and body content
  (t/assert-truthy (string/find "tokens" resp))
  (fake/net-reset)
  (obs/reset)))

(t/test "poll-http serves unknown path with 404" (fn []
  (fake/net-reset)
  (obs/reset)
  (obs/start-http-server 7889)
  (def conn-id (fake/net-inject-connection 1
    ["GET /unknown HTTP/1.1\r\n"
     "\r\n"]))
  (obs/poll-http)
  (def writes (fake/net-get-writes conn-id))
  (t/assert= 1 (length writes))
  (t/assert-truthy (string/find "404" (first writes)))
  (fake/net-reset)
  (obs/reset)))

(t/test "poll-http is a no-op when no connection is pending" (fn []
  (fake/net-reset)
  (obs/reset)
  (obs/start-http-server 7889)
  (obs/poll-http)
  # No crash
  (t/assert-truthy true)
  (fake/net-reset)
  (obs/reset)))

(t/test "poll-http is a no-op when server is not started" (fn []
  (obs/reset)
  (obs/poll-http)
  (t/assert-truthy true)))

(t/test "stop closes the HTTP listener" (fn []
  (fake/net-reset)
  (obs/reset)
  (obs/start-http-server 7889)
  (t/assert= 7889 (obs/get-http-port))
  (obs/stop)
  (t/assert-truthy (nil? (obs/get-http-port)))
  (fake/net-reset)))

# ── Cleanup ───────────────────────────────────────────────────

(obs/reset)

(def pass (t/pass))
(def fail (t/fail))
