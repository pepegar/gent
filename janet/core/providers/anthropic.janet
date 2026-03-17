# Anthropic Messages API provider.
# Extracted from core/api.janet — handles Anthropic-specific wire format:
# headers, request body, SSE stream parsing, model listing.

(import core/auth :as auth)

# ── Constants ────────────────────────────────────────────────

(def- anthropic-version "2023-06-01")
(def- claude-code-identity "You are Claude Code, Anthropic's official CLI for Claude.")

# ── Helpers ──────────────────────────────────────────────────

(defn- using-custom-url? [config]
  "Check if the API URL is overridden (not the default Anthropic endpoint)."
  (not= (config :url) "https://api.anthropic.com/v1/messages"))

(defn- oauth-token? [config]
  "Check if the current credential is an OAuth token.
   Returns false when using a custom URL — OAuth tokens are Anthropic-specific."
  (when (using-custom-url? config) (break false))
  (when (config :api-key) (break false))
  (when (os/getenv "GENT_API_KEY") (break false))
  (def cred (auth/get-credential "anthropic"))
  (and cred (= "oauth" (get cred "type"))))

(defn- wrap-system-prompt [config system-prompt]
  "For OAuth tokens, prepend Claude Code identity to the system prompt.
   Uses array-of-blocks format so the identity is a separate content block."
  (if (oauth-token? config)
    (if system-prompt
      [{:type "text" :text claude-code-identity}
       {:type "text" :text system-prompt}]
      claude-code-identity)
    system-prompt))

# ── Provider functions ───────────────────────────────────────

(defn build-headers [config]
  "Build HTTP headers for an Anthropic API request."
  (def api-key (config :resolved-api-key))
  (def is-oauth (oauth-token? config))
  (def custom-url (using-custom-url? config))
  (def headers
    @{"content-type" "application/json"
      "anthropic-version" anthropic-version})
  (cond
    is-oauth
    (do
      (put headers "authorization" (string "Bearer " api-key))
      (put headers "anthropic-beta" "claude-code-20250219,oauth-2025-04-20")
      (put headers "anthropic-dangerous-direct-browser-access" "true")
      (put headers "user-agent" "claude-cli/2.1.2 (external, cli)")
      (put headers "x-app" "cli"))

    custom-url
    (put headers "authorization" (string "Bearer " api-key))

    # Default Anthropic API with API key
    (put headers "x-api-key" api-key))
  headers)

(defn convert-tools [tools]
  "Convert tool definitions to Anthropic format (already in canonical form)."
  tools)

(defn build-body [config conversation tools &opt system-prompt]
  "Build Anthropic request body with stream:true. Returns JSON string."
  (def budget (config :thinking-budget))
  (def max-tok (config :max-tokens))
  (def body @{:model (config :model)
              :max_tokens (if (and (config :thinking-enabled) (<= max-tok budget))
                            (+ budget 4096)
                            max-tok)
              :messages conversation
              :tools tools
              :stream true})
  (when (config :thinking-enabled)
    (put body :thinking @{:type "enabled"
                          :budget_tokens budget}))
  (def effective-prompt (wrap-system-prompt config system-prompt))
  (when effective-prompt
    (put body :system effective-prompt))
  (json/encode body))

(defn new-stream-parser
  ``Create a new SSE stream parser for Anthropic's event format.

  callbacks: a table of callback functions:
    :on-text        (fn [text])           — called with each text delta
    :on-thinking    (fn [text])           — called with each thinking delta (optional)
    :on-tool-start  (fn [name])           — called when a tool_use block starts streaming
    :on-tool-delta  (fn [name nbytes])    — called on each input_json_delta with accumulated size
    :on-tool-use    (fn [id name input])  — called when a tool_use block is complete
    :on-error       (fn [err])            — called on error

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
  (def thinking-accum @"")
  (def thinking-signature @"")
  (var usage nil)
  (var had-error false)

  (defn feed-line [line]
    "Process a single SSE line. Returns nil."
    (when (string/has-prefix? "data: " line)
      (def data-str (string/slice line 6))
      (when (= data-str "[DONE]") (break))
      (def event (json/decode data-str))
      (when (nil? event) (break))
      (def etype (get event :type))

      (case etype
        "message_start"
        (do
          (def msg (get event :message))
          (when msg
            (set stop-reason (get msg :stop_reason))))

        "content_block_start"
        (do
          (def idx (get event :index))
          (def block (get event :content_block))
          (set current-block-index idx)
          (set current-block-type (get block :type))
          (when (= "tool_use" current-block-type)
            (set current-tool-id (get block :id))
            (set current-tool-name (get block :name))
            (buffer/clear current-input-json)
            (when-let [cb (get callbacks :on-tool-start)]
              (cb current-tool-name)))
          (when (= "text" current-block-type)
            (buffer/clear text-accum))
          (when (= "thinking" current-block-type)
            (buffer/clear thinking-accum)
            (buffer/clear thinking-signature)))

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
              (buffer/push thinking-accum text)
              (when-let [cb (get callbacks :on-thinking)]
                (cb text)))

            "signature_delta"
            (do
              (def sig (get delta :signature ""))
              (buffer/push thinking-signature sig))

            "input_json_delta"
            (do
              (def partial (get delta :partial_json ""))
              (buffer/push current-input-json partial)
              (when-let [cb (get callbacks :on-tool-delta)]
                (cb current-tool-name (length current-input-json))))))

        "content_block_stop"
        (do
          (case current-block-type
            "text"
            (array/push content-blocks
              {:type "text" :text (string text-accum)})

            "thinking"
            (do
              (def block @{:type "thinking"
                           :thinking (string thinking-accum)})
              (when (> (length thinking-signature) 0)
                (put block :signature (string thinking-signature)))
              (array/push content-blocks block))

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

        "message_delta"
        (do
          (def delta (get event :delta))
          (when delta
            (set stop-reason (get delta :stop_reason stop-reason)))
          (set usage (get event :usage)))

        "message_stop"
        nil

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

(defn list-models [config]
  "Fetch available models from Anthropic. Returns array of model tables or nil."
  (def headers (build-headers config))
  (def url (config :url))
  (def parts (string/split "/" url))
  (put parts (- (length parts) 1) "models")
  (def base-url (string/join parts "/"))
  (def all-models @[])
  (var after-id nil)
  (var keep-going true)
  (while keep-going
    (def req-url
      (if after-id
        (string base-url "?after_id=" after-id "&limit=100")
        (string base-url "?limit=100")))
    (def response (http/request "GET" req-url headers nil))
    (when (nil? response)
      (set keep-going false)
      (break))
    (def parsed (json/decode response))
    (when (nil? parsed)
      (set keep-going false)
      (break))
    (def data (get parsed :data))
    (when (or (nil? data) (not (indexed? data)))
      (set keep-going false)
      (break))
    (array/concat all-models data)
    (if (get parsed :has_more)
      (set after-id (get parsed :last_id))
      (set keep-going false)))
  (if (empty? all-models) nil all-models))

(defn build-body-no-stream [config conversation tools &opt system-prompt]
  "Build Anthropic request body without streaming. Returns JSON string."
  (def budget (config :thinking-budget))
  (def max-tok (config :max-tokens))
  (def body @{:model (config :model)
              :max_tokens (if (and (config :thinking-enabled) (<= max-tok budget))
                            (+ budget 4096)
                            max-tok)
              :messages conversation
              :tools tools})
  (when (config :thinking-enabled)
    (put body :thinking @{:type "enabled"
                          :budget_tokens budget}))
  (def effective-prompt (wrap-system-prompt config system-prompt))
  (when effective-prompt
    (put body :system effective-prompt))
  (json/encode body))
