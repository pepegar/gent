# Anthropic Messages API — builds requests and parses responses.
# All HTTP is done via the native http/request function provided by Rust.
#
# Configuration priority: set-* functions > environment variables > defaults.
# Environment variables:
#   GENT_API_URL    — API endpoint (default: Anthropic)
#   GENT_API_KEY    — API key (falls back to ANTHROPIC_API_KEY)
#   GENT_MODEL      — model name
#   GENT_MAX_TOKENS — max tokens per response

(def- defaults
  {:url "https://api.anthropic.com/v1/messages"
   :model "claude-sonnet-4-20250514"
   :max-tokens 8192})

# Mutable config — env vars override defaults, set-* overrides everything
(var- config
  @{:url (or (os/getenv "GENT_API_URL") (defaults :url))
    :model (or (os/getenv "GENT_MODEL") (defaults :model))
    :max-tokens (let [env (os/getenv "GENT_MAX_TOKENS")]
                  (if env (scan-number env) (defaults :max-tokens)))
    :api-key (or (os/getenv "GENT_API_KEY") (os/getenv "ANTHROPIC_API_KEY"))})

(defn set-url [url] (put config :url url))
(defn set-model [m] (put config :model m))
(defn set-max-tokens [n] (put config :max-tokens n))
(defn set-api-key [k] (put config :api-key k))

(defn get-config
  "Return the current API configuration (for introspection)."
  []
  (table/clone config))

(defn- build-headers []
  (def api-key (config :api-key))
  (unless api-key
    (error "No API key set. Use GENT_API_KEY, ANTHROPIC_API_KEY, or (api/set-api-key ...)"))
  @{"content-type" "application/json"
    "x-api-key" api-key
    "anthropic-version" "2023-06-01"})

(defn- build-body [conversation tools &opt system-prompt]
  (def body @{:model (config :model)
              :max_tokens (config :max-tokens)
              :messages conversation
              :tools tools})
  (when system-prompt
    (put body :system system-prompt))
  (json/encode body))

(defn chat
  "Send a conversation to Claude. Returns the parsed response message.
   conversation: array of {:role ... :content ...}
   tools: array of tool definitions (from tools/definitions)
   &opt system-prompt: string"
  [conversation tools &opt system-prompt]
  (def headers (build-headers))
  (def body (build-body conversation tools system-prompt))
  (def response (http/request "POST" (config :url) headers body))
  (when (nil? response)
    (error "API request failed — got nil response"))
  (json/decode response))

(defn- build-body-stream [conversation tools &opt system-prompt]
  "Build request body with stream: true."
  (def body @{:model (config :model)
              :max_tokens (config :max-tokens)
              :messages conversation
              :tools tools
              :stream true})
  (when system-prompt
    (put body :system system-prompt))
  (json/encode body))

# ── SSE stream parser ──────────────────────────────────────────
#
# A stateful parser that processes SSE lines one at a time.
# Create with (new-stream-parser callbacks), feed lines with (:feed parser line),
# finalize with (:finish parser) to get the reconstructed response.

(defn new-stream-parser
  ``Create a new SSE stream parser.

  callbacks: a table of callback functions:
    :on-text      (fn [text])           — called with each text delta
    :on-thinking  (fn [text])           — called with each thinking delta (optional)
    :on-tool-use  (fn [id name input])  — called when a tool_use block is complete
    :on-error     (fn [err])            — called on error

  Returns a parser table with :feed and :finish methods.
  ``
  [callbacks]
  (var stop-reason nil)
  (var current-block-type nil)
  (var current-block-index nil)
  (var current-tool-id nil)
  (var current-tool-name nil)
  (var current-input-json @"")
  (def content-blocks @[])
  (def text-accum @"")
  (var usage nil)
  (var had-error false)

  (defn feed-line [line]
    "Process a single SSE line. Returns nil."
    # SSE lines: "data: {...}" or "event: ..." or empty
    (when (string/has-prefix? "data: " line)
      (def data-str (string/slice line 6))

      # [DONE] marker
      (when (= data-str "[DONE]") (break))

      (def event (json/decode data-str))
      (when (nil? event) (break))

      (def etype (get event :type))

      (case etype
        # message_start — contains the message skeleton
        "message_start"
        (do
          (def msg (get event :message))
          (when msg
            (set stop-reason (get msg :stop_reason))))

        # content_block_start — a new content block begins
        "content_block_start"
        (do
          (def idx (get event :index))
          (def block (get event :content_block))
          (set current-block-index idx)
          (set current-block-type (get block :type))
          (when (= "tool_use" current-block-type)
            (set current-tool-id (get block :id))
            (set current-tool-name (get block :name))
            (buffer/clear current-input-json))
          (when (= "text" current-block-type)
            (buffer/clear text-accum)))

        # content_block_delta — incremental content
        "content_block_delta"
        (do
          (def delta (get event :delta))
          (def dtype (get delta :type))
          (case dtype
            "text_delta"
            (do
              (def text (get delta :text ""))
              (buffer/push text-accum text)
              (when-let [cb (get callbacks :on-text)]
                (cb text)))

            "thinking_delta"
            (do
              (def text (get delta :thinking ""))
              (when-let [cb (get callbacks :on-thinking)]
                (cb text)))

            "input_json_delta"
            (do
              (def partial (get delta :partial_json ""))
              (buffer/push current-input-json partial))))

        # content_block_stop — block is complete
        "content_block_stop"
        (do
          (case current-block-type
            "text"
            (array/push content-blocks
                        {:type "text" :text (string text-accum)})

            "tool_use"
            (do
              (def parsed-input (json/decode (string current-input-json)))
              (def block {:type "tool_use"
                          :id current-tool-id
                          :name current-tool-name
                          :input (or parsed-input @{})})
              (array/push content-blocks block)
              (when-let [cb (get callbacks :on-tool-use)]
                (cb current-tool-id current-tool-name (or parsed-input @{})))))

          (set current-block-type nil))

        # message_delta — final stop_reason, usage
        "message_delta"
        (do
          (def delta (get event :delta))
          (when delta
            (set stop-reason (get delta :stop_reason stop-reason)))
          (set usage (get event :usage)))

        # message_stop — stream is done
        "message_stop"
        nil

        # error
        "error"
        (do
          (set had-error true)
          (def err-msg (get-in event [:error :message] "unknown streaming error"))
          (when-let [cb (get callbacks :on-error)]
            (cb err-msg))))))

  (defn finish []
    "Finalize and return the reconstructed response."
    (def response @{:role "assistant"
                     :content content-blocks
                     :stop_reason stop-reason
                     :type "message"})
    (when usage (put response :usage usage))
    response)

  @{:feed feed-line
    :finish finish
    :had-error (fn [] had-error)})

(defn stream-start
  ``Start a non-blocking streaming request to Claude.

  Returns a table with:
    :parser   — the SSE stream parser (feed lines with (:feed parser line))
    :headers  — the request headers (for reference)

  Use http/stream-read to get lines, feed them to the parser.
  Call (:finish (:parser result)) when done to get the response.
  ``
  [conversation tools callbacks &opt system-prompt]
  (def headers (build-headers))
  (def body (build-body-stream conversation tools system-prompt))
  (def parser (new-stream-parser callbacks))

  # Start the background HTTP stream
  (http/stream-start "POST" (config :url) headers body)

  @{:parser parser})

(defn chat-stream
  ``Send a conversation to Claude with SSE streaming (blocking).

  callbacks: a table of callback functions:
    :on-text      (fn [text])           — called with each text delta
    :on-thinking  (fn [text])           — called with each thinking delta (optional)
    :on-tool-use  (fn [id name input])  — called when a tool_use block is complete
    :on-done      (fn [response])       — called with the reconstructed full response
    :on-error     (fn [err])            — called on error

  Returns the full reconstructed response (same shape as non-streaming chat).
  ``
  [conversation tools callbacks &opt system-prompt]
  (def headers (build-headers))
  (def body (build-body-stream conversation tools system-prompt))

  (def parser (new-stream-parser callbacks))

  # Make the streaming request (blocking — calls parser for each line)
  (def result
    (try
      (http/stream "POST" (config :url) headers body (fn [line] ((parser :feed) line)))
      ([err]
        (when-let [cb (get callbacks :on-error)]
          (cb (string err)))
        nil)))

  (def response ((parser :finish)))

  # Call on-done callback
  (when-let [cb (get callbacks :on-done)]
    (cb response))

  response)
