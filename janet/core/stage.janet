# core/stage.janet — Scriptable LLM backend for testing, profiling, and demos.
#
# The "stage provider" replaces the real API+HTTP streaming layer with a
# queue of scripted responses. Each call to chat/submit pops the next
# queued response and drip-feeds its SSE lines through stream-read with
# configurable timing.
#
# Usage:
#   (import core/stage :as stage)
#   (stage/install)
#   (stage/respond (stage/text "Hello from the stage!"))
#   (stage/respond (stage/text-stream "Token by token" :token-delay 0.05))

(import core/api :as api)
(import widgets/chat :as chat)

# ── Response queue ────────────────────────────────────────────

(var- response-queue @[])
(var- active-stream nil)

# ── Stream state (drip-feeds SSE lines with timing) ──────────

(var- stream-state @{:lines @[] :index 0 :last-time 0 :delay 0})

# ── SSE line helpers ─────────────────────────────────────────

(defn- sse-line [data]
  "Wrap a data table as an SSE data: line."
  (string "data: " (json/encode data)))

(defn- utf8-chars [text]
  "Split a string into individual UTF-8 characters."
  (def result @[])
  (var i 0)
  (while (< i (length text))
    (def byte (get text i))
    (def char-len
      (cond (< byte 0x80) 1 (< byte 0xE0) 2 (< byte 0xF0) 3 4))
    (def end (min (+ i char-len) (length text)))
    (array/push result (string/slice text i end))
    (set i end))
  result)

(defn- generate-sse-lines [gen]
  "Convert a response generator table to an array of SSE lines."
  (def lines @[])
  (def gtype (gen :type))

  (cond
    (= gtype :text)
    (do
      (array/push lines (sse-line @{:type "message_start"
                                     :message @{:id "msg_stage" :type "message"
                                                :role "assistant" :content @[]
                                                :model "stage" :stop_reason nil}}))
      (array/push lines (sse-line @{:type "content_block_start" :index 0
                                     :content_block @{:type "text" :text ""}}))
      (array/push lines (sse-line @{:type "content_block_delta" :index 0
                                     :delta @{:type "text_delta"
                                              :text (gen :content)}}))
      (array/push lines (sse-line @{:type "content_block_stop" :index 0}))
      (array/push lines (sse-line @{:type "message_delta"
                                     :delta @{:stop_reason "end_turn"}}))
      (array/push lines (sse-line @{:type "message_stop"}))
      (array/push lines "data: [DONE]"))

    (= gtype :text-stream)
    (do
      (array/push lines (sse-line @{:type "message_start"
                                     :message @{:id "msg_stage" :type "message"
                                                :role "assistant" :content @[]
                                                :model "stage" :stop_reason nil}}))
      (array/push lines (sse-line @{:type "content_block_start" :index 0
                                     :content_block @{:type "text" :text ""}}))
      (each ch (utf8-chars (gen :content))
        (array/push lines (sse-line @{:type "content_block_delta" :index 0
                                       :delta @{:type "text_delta" :text ch}})))
      (array/push lines (sse-line @{:type "content_block_stop" :index 0}))
      (array/push lines (sse-line @{:type "message_delta"
                                     :delta @{:stop_reason "end_turn"}}))
      (array/push lines (sse-line @{:type "message_stop"}))
      (array/push lines "data: [DONE]"))

    (= gtype :tool-call)
    (do
      (array/push lines (sse-line @{:type "message_start"
                                     :message @{:id "msg_stage" :type "message"
                                                :role "assistant" :content @[]
                                                :model "stage" :stop_reason nil}}))
      (array/push lines (sse-line @{:type "content_block_start" :index 0
                                     :content_block @{:type "tool_use"
                                                      :id (or (gen :id) "stage_tool_1")
                                                      :name (gen :name)
                                                      :input @{}}}))
      (array/push lines (sse-line @{:type "content_block_delta" :index 0
                                     :delta @{:type "input_json_delta"
                                              :partial_json (json/encode (gen :input))}}))
      (array/push lines (sse-line @{:type "content_block_stop" :index 0}))
      (array/push lines (sse-line @{:type "message_delta"
                                     :delta @{:stop_reason "tool_use"}}))
      (array/push lines (sse-line @{:type "message_stop"}))
      (array/push lines "data: [DONE]"))

    (= gtype :custom)
    (do
      (def custom-lines ((gen :function) (gen :conversation)))
      (each l custom-lines
        (array/push lines l))))

  lines)

# ── Response generators ──────────────────────────────────────

(defn text [content &named delay]
  "Generate a text response. delay = seconds between SSE lines."
  @{:type :text :content content :delay (if (nil? delay) 0 delay)})

(defn text-stream [content &named token-delay]
  "Generate a text response streamed token-by-token.
   token-delay = seconds between each token (default 0.05 = 50ms)."
  @{:type :text-stream :content content :delay (if (nil? token-delay) 0.05 token-delay)})

(defn tool-call [name input &named id delay]
  "Generate a tool call response."
  @{:type :tool-call :name name :input input
    :id (if (nil? id) "stage_tool_1" id) :delay (if (nil? delay) 0 delay)})

(defn custom [f]
  "Custom generator: (fn [conversation] ...) returns SSE lines."
  @{:type :custom :function f :delay 0})

# ── Queue management ─────────────────────────────────────────

(defn respond [generator]
  "Queue a response generator for the next submit."
  (array/push response-queue generator))

(defn sequence [responses]
  "Queue multiple responses for a multi-turn conversation."
  (each r responses (respond r)))

(defn clear-queue []
  "Clear all queued responses."
  (array/clear response-queue))

(defn queue-length []
  "Return the number of queued responses."
  (length response-queue))

# ── Stage provider functions ─────────────────────────────────

(defn- stage-stream-start [conversation tools callbacks &opt system-prompt]
  (def gen (if (not (empty? response-queue))
             (do (def g (first response-queue))
                 (array/remove response-queue 0)
                 g)
             (text "(no response queued)")))
  (when (= (gen :type) :custom)
    (put gen :conversation conversation))
  (def lines (generate-sse-lines gen))
  (def parser (api/new-stream-parser callbacks))
  (put stream-state :lines lines)
  (put stream-state :index 0)
  (put stream-state :last-time (os/clock))
  (put stream-state :delay (or (gen :delay) 0))
  (set active-stream true)
  @{:parser parser :stream-id :stage})

(defn- stage-stream-read [stream-id]
  (def now (os/clock))
  (def elapsed (- now (stream-state :last-time)))
  (def delay (stream-state :delay))
  (if (and (> delay 0) (< elapsed delay))
    nil
    (do
      (def idx (stream-state :index))
      (def lines (stream-state :lines))
      (if (>= idx (length lines))
        :done
        (do
          (put stream-state :index (+ idx 1))
          (put stream-state :last-time now)
          (get lines idx))))))

(defn- stage-stream-stop [stream-id]
  (set active-stream nil))

# ── Install ──────────────────────────────────────────────────

(defn install []
  "Install the stage provider into chat.janet."
  (chat/set-provider
    @{:stream-start stage-stream-start
      :stream-read stage-stream-read
      :stream-stop stage-stream-stop}))

# ── State accessors (for testing) ────────────────────────────

(defn active? []
  "Return whether a stage stream is currently active."
  (truthy? active-stream))

(defn reset []
  "Reset all stage state."
  (array/clear response-queue)
  (set active-stream nil)
  (put stream-state :lines @[])
  (put stream-state :index 0)
  (put stream-state :last-time 0)
  (put stream-state :delay 0))
