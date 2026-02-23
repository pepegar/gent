# test/fake-api.janet — SSE response builders for testing.
#
# Builds arrays of SSE "data: ..." lines that mimic the Anthropic
# streaming API, for feeding into fake-http queues or the SSE parser.
#
# Usage:
#   (import test/fake-api :as fake-api)
#   (fake/queue-lines (fake-api/text-response "Hello!"))
#   (fake/queue-lines (fake-api/tool-call-response "tool_1" "bash" {:command "ls"}))

(import test/json :as json)

(defn text-response
  "Build SSE lines for a simple text response.
   Streams the text in a single delta."
  [text]
  (def escaped (string/replace-all `"` `\"` (string/replace-all `\` `\\` text)))
  @[(string `data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"test","stop_reason":null}}`)
    (string `data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`)
    (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"` escaped `"}}`)
    (string `data: {"type":"content_block_stop","index":0}`)
    (string `data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}`)
    (string `data: {"type":"message_stop"}`)
    "data: [DONE]"])

(defn text-response-chunked
  "Build SSE lines for a text response streamed in multiple deltas."
  [chunks]
  (def lines @[])
  (array/push lines
    (string `data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"test","stop_reason":null}}`))
  (array/push lines
    (string `data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`))
  (each chunk chunks
    (def escaped (string/replace-all `"` `\"` (string/replace-all `\` `\\` chunk)))
    (array/push lines
      (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"` escaped `"}}`)))
  (array/push lines (string `data: {"type":"content_block_stop","index":0}`))
  (array/push lines (string `data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}`))
  (array/push lines (string `data: {"type":"message_stop"}`))
  (array/push lines "data: [DONE]")
  lines)

(defn tool-call-response
  "Build SSE lines for a tool_use response.
   input should be a Janet table (will be encoded as JSON)."
  [tool-id tool-name input]
  (def input-json (json/encode input))
  (def escaped-name (string/replace-all `"` `\"` tool-name))
  @[(string `data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"test","stop_reason":null}}`)
    (string `data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"` tool-id `","name":"` escaped-name `","input":{}}}`)
    (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"` (string/replace-all `"` `\"` input-json) `"}}`)
    (string `data: {"type":"content_block_stop","index":0}`)
    (string `data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}`)
    (string `data: {"type":"message_stop"}`)
    "data: [DONE]"])

(defn text-then-tool-response
  "Build SSE lines for a response with text followed by a tool call."
  [text tool-id tool-name input]
  (def escaped-text (string/replace-all `"` `\"` (string/replace-all `\` `\\` text)))
  (def input-json (json/encode input))
  (def escaped-name (string/replace-all `"` `\"` tool-name))
  @[(string `data: {"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","content":[],"model":"test","stop_reason":null}}`)
    # Text block
    (string `data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`)
    (string `data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"` escaped-text `"}}`)
    (string `data: {"type":"content_block_stop","index":0}`)
    # Tool use block
    (string `data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"` tool-id `","name":"` escaped-name `","input":{}}}`)
    (string `data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"` (string/replace-all `"` `\"` input-json) `"}}`)
    (string `data: {"type":"content_block_stop","index":1}`)
    (string `data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}`)
    (string `data: {"type":"message_stop"}`)
    "data: [DONE]"])

(defn error-response
  "Build SSE lines for an error response."
  [message]
  (def escaped (string/replace-all `"` `\"` message))
  @[(string `data: {"type":"error","error":{"type":"api_error","message":"` escaped `"}}`)
    "data: [DONE]"])
