# OpenAI Codex Responses API provider.
# Handles OpenAI-specific wire format: headers, request body, SSE stream
# parsing, and message format conversion to/from canonical format.
#
# Supports two endpoints:
#   - ChatGPT Codex: https://chatgpt.com/backend-api/codex/responses (OAuth)
#   - OpenAI API: https://api.openai.com/v1/responses (API key)

(import core/auth :as auth)

# ── Constants ────────────────────────────────────────────────

(def- default-url "https://chatgpt.com/backend-api/codex/responses")
(def- default-model "gpt-5.1")
(def- default-max-tokens 16384)

# ── Helpers ──────────────────────────────────────────────────

(defn- codex-url? [url]
  "Check if the URL is the ChatGPT Codex endpoint (uses different auth)."
  (string/has-prefix? "https://chatgpt.com/" url))

(defn- extract-account-id-from-jwt [token]
  "Extract the chatgpt_account_id from a JWT access token.
   JWT format: header.payload.signature (base64url-encoded).
   Returns the accountId string, or nil."
  (def parts (string/split "." token))
  (when (< (length parts) 2) (break nil))
  (def payload-b64 (get parts 1))
  # Re-pad base64url → base64
  (def padded
    (let [remainder (% (length payload-b64) 4)]
      (if (= remainder 0)
        payload-b64
        (string payload-b64 (string/repeat "=" (- 4 remainder))))))
  # base64url → base64: replace - with + and _ with /
  (def b64 (->> padded
                (string/replace-all "-" "+")
                (string/replace-all "_" "/")))
  # Decode via shell
  (def result
    (process/exec "sh" ["-c"
                        (string "printf '%s' '" b64 "' | base64 -d 2>/dev/null || printf '%s' '" b64 "' | base64 -D 2>/dev/null")]))
  (when (not= 0 (result :status)) (break nil))
  (def payload (try (json/decode (result :stdout)) ([_] nil)))
  (when (nil? payload) (break nil))
  (def auth-claim (get payload (keyword "https://api.openai.com/auth")))
  (when (nil? auth-claim) (break nil))
  (get auth-claim :chatgpt_account_id))

# ── Headers ──────────────────────────────────────────────────

(defn build-headers [config]
  "Build HTTP headers for an OpenAI API request."
  (def api-key (config :resolved-api-key))
  (def headers
    @{"content-type" "application/json"
      "authorization" (string "Bearer " api-key)
      "accept" "text/event-stream"})
  # For Codex endpoint, extract account-id from JWT and add beta headers
  (when (codex-url? (config :url))
    (def account-id (extract-account-id-from-jwt api-key))
    (when account-id
      (put headers "chatgpt-account-id" account-id))
    (put headers "OpenAI-Beta" "responses=experimental")
    (put headers "originator" "gent"))
  headers)

# ── Tool conversion ──────────────────────────────────────────

(defn convert-tools [tools]
  "Convert canonical tool definitions to OpenAI function format.
   Canonical: {:name :description :input_schema {:type 'object' ...}}
   OpenAI:    {:type 'function' :name :description :parameters {:type 'object' ...}}"
  (map (fn [t]
        @{:type "function"
          :name (t :name)
          :description (t :description)
          :parameters (t :input_schema)})
    tools))

# ── Message conversion (canonical → OpenAI Responses API) ────

(defn- convert-user-message [msg]
  "Convert a canonical user message to OpenAI input format.
   Handles both string content and structured content (tool_result)."
  (def content (msg :content))
  (if (string? content)
    # Simple text message
    @{:role "user"
      :content @[@{:type "input_text" :text content}]}
    # Structured content — may contain tool_result blocks
    (if (indexed? content)
      (do
        (def results @[])
        (each block content
          (def btype (get block :type))
          (cond
            (= btype "tool_result")
            (array/push results
              @{:type "function_call_output"
                :call_id (get block :tool_use_id)
                :output (if (string? (get block :content))
                          (get block :content)
                          (json/encode (get block :content)))})

            (= btype "text")
            (array/push results
              @{:role "user"
                :content @[@{:type "input_text" :text (get block :text)}]})

            # Default: treat as text
            (array/push results
              @{:role "user"
                :content @[@{:type "input_text" :text (json/encode block)}]})))
        results)
      # Fallback: encode as-is
      @[@{:role "user"
          :content @[@{:type "input_text" :text (json/encode content)}]}])))

(var- msg-counter 0)

(defn- convert-assistant-message [msg]
  "Convert a canonical assistant message to OpenAI input format.
   Content blocks: text → output_text, tool_use → function_call, thinking → reasoning."
  (def content (msg :content))
  (def results @[])
  (def text-parts @[])

  (each block content
    (def btype (get block :type))
    (cond
      (= btype "text")
      (array/push text-parts @{:type "output_text" :text (get block :text)})

      (= btype "tool_use")
      (do
        # Flush any accumulated text parts as a message
        (when (> (length text-parts) 0)
          (array/push results
            @{:type "message"
              :role "assistant"
              :content (array/slice text-parts)
              :status "completed"
              :id (string "msg_" (++ msg-counter))})
          (array/clear text-parts))
        (array/push results
          @{:type "function_call"
            :call_id (get block :id)
            :name (get block :name)
            :arguments (json/encode (get block :input))}))

      (= btype "thinking")
      (do
        (def reasoning @{:type "reasoning"})
        (when (get block :signature)
          (put reasoning :encrypted_content (get block :signature)))
        # OpenAI requires a summary field on reasoning items sent back
        (def thinking-text (get block :thinking ""))
        (put reasoning :summary
          (if (not= "" thinking-text)
            @[@{:type "summary_text" :text thinking-text}]
            @[@{:type "summary_text" :text "(reasoning)"}]))
        (array/push results reasoning))))

  # Flush remaining text parts
  (when (> (length text-parts) 0)
    (array/push results
      @{:type "message"
        :role "assistant"
        :content (array/slice text-parts)
        :status "completed"
        :id (string "msg_" (++ msg-counter))}))

  results)

(defn- convert-messages-to-openai [conversation]
  "Convert canonical conversation to OpenAI Responses API input array."
  (set msg-counter 0)
  (def input @[])
  (each msg conversation
    (def role (msg :role))
    (cond
      (= role "user")
      (do
        (def converted (convert-user-message msg))
        (if (and (indexed? converted) (> (length converted) 0)
                 (get (first converted) :type))
          # Already flat array of items (from tool_result conversion)
          (array/concat input converted)
          # Single message
          (array/push input converted)))

      (= role "assistant")
      (do
        (def converted (convert-assistant-message msg))
        (array/concat input converted))))
  input)

# ── Request body ─────────────────────────────────────────────

(defn build-body [config conversation tools &opt system-prompt]
  "Build OpenAI Responses API request body with stream:true. Returns JSON string."
  (def input (convert-messages-to-openai conversation))
  (def body @{:model (config :model)
              :store false
              :stream true
              :input input
              :tool_choice "auto"
              :parallel_tool_calls true})
  (when system-prompt
    (put body :instructions system-prompt))
  (when tools
    (put body :tools tools))
  (when (config :thinking-enabled)
    (put body :reasoning @{:effort "high" :summary "auto"})
    (put body :include @["reasoning.encrypted_content"]))
  (json/encode body))

# ── SSE stream parser ────────────────────────────────────────
#
# OpenAI Responses API emits events like:
#   response.output_item.added  — new item in output
#   response.output_text.delta  — text chunk
#   response.function_call_arguments.delta — tool JSON chunk
#   response.output_item.done   — item finalized
#   response.completed          — stream done

(defn new-stream-parser
  ``Create a new SSE stream parser for OpenAI's Responses API event format.

  callbacks: same interface as Anthropic parser.
  Returns a parser table with :feed and :finish methods.
  ``
  [callbacks]
  (var stop-reason nil)
  (def content-blocks @[])
  (var had-error false)

  # Track current items by index
  (def items @{})
  (var usage nil)

  (defn feed-line [line]
    "Process a single SSE line."
    # OpenAI SSE: "event: type\ndata: {...}" or just "data: {...}"
    # We get individual lines, so we track the event type
    (when (string/has-prefix? "data: " line)
      (def data-str (string/slice line 6))
      (when (= data-str "[DONE]") (break))

      (def event (json/decode data-str))
      (when (nil? event) (break))

      (def etype (get event :type))

      (case etype
        # New output item started
        "response.output_item.added"
        (do
          (def item (get event :item))
          (when item
            (def idx (get event :output_index 0))
            (def itype (get item :type))
            (put items idx @{:type itype :data item})
            (cond
              (= itype "function_call")
              (do
                (def name (get item :name))
                (put items idx @{:type itype :name name :call-id (get item :call_id)
                                 :arguments @""})
                (when-let [cb (get callbacks :on-tool-start)]
                  (cb name)))

              (= itype "message")
              (put items idx @{:type itype :text @""})

              (= itype "reasoning")
              (put items idx @{:type itype :text @"" :summary @""}))))

        # Text delta
        "response.output_text.delta"
        (do
          (def text (get event :delta ""))
          (def idx (get event :output_index 0))
          (when-let [item (get items idx)]
            (buffer/push (item :text) text))
          (when-let [cb (get callbacks :on-text)]
            (cb text)))

        # Reasoning summary delta
        "response.reasoning_summary_text.delta"
        (do
          (def text (get event :delta ""))
          (when-let [cb (get callbacks :on-thinking)]
            (cb text))
          # Find the reasoning item
          (eachp [idx item] items
            (when (= (item :type) "reasoning")
              (buffer/push (item :summary) text))))

        # Function call arguments delta
        "response.function_call_arguments.delta"
        (do
          (def delta (get event :delta ""))
          (def idx (get event :output_index 0))
          (when-let [item (get items idx)]
            (buffer/push (item :arguments) delta)
            (when-let [cb (get callbacks :on-tool-delta)]
              (cb (item :name) (length (item :arguments))))))

        # Output item done
        "response.output_item.done"
        (do
          (def item (get event :item))
          (when item
            (def itype (get item :type))
            (cond
              (= itype "message")
              (do
                # Extract text content from the finalized item
                (def item-content (get item :content @[]))
                (each part item-content
                  (when (= (get part :type) "output_text")
                    (array/push content-blocks
                      {:type "text" :text (get part :text "")}))))

              (= itype "function_call")
              (do
                (def call-id (get item :call_id))
                (def name (get item :name))
                (def args-str (get item :arguments "{}"))
                (def parsed-input (json/decode args-str))
                (array/push content-blocks
                  {:type "tool_use"
                   :id call-id
                   :name name
                   :input (or parsed-input @{})})
                (when-let [cb (get callbacks :on-tool-use)]
                  (cb call-id name (or parsed-input @{}))))

              (= itype "reasoning")
              (do
                (def block @{:type "thinking"
                             :thinking ""})
                # Use summary text if available
                (def idx (get event :output_index 0))
                (when-let [tracked (get items idx)]
                  (when (> (length (tracked :summary)) 0)
                    (put block :thinking (string (tracked :summary)))))
                # Extract encrypted_content as signature
                (def encrypted (get item :encrypted_content))
                (when encrypted
                  (put block :signature encrypted))
                (when (or (not= "" (block :thinking))
                          (block :signature))
                  (array/push content-blocks block))))))

        # Response completed
        "response.completed"
        (do
          (def response (get event :response))
          (when response
            (def status (get response :status))
            (set stop-reason
              (cond
                (= status "completed") "end_turn"
                (= status "incomplete") "max_tokens"
                status))
            (set usage (get response :usage))))

        # Response failed
        "response.failed"
        (do
          (set had-error true)
          (def response (get event :response))
          (def err-msg
            (or (get-in response [:error :message])
                (get-in event [:error :message])
                "unknown streaming error"))
          (set stop-reason "error")
          (when-let [cb (get callbacks :on-error)]
            (cb err-msg)))

        # response.created, response.in_progress — ignore
        nil)))

  (defn finish []
    "Finalize and return the reconstructed response in canonical format."
    # Check if any function_calls exist → stop_reason should be "tool_use"
    (when (nil? stop-reason)
      (set stop-reason "end_turn"))
    (each block content-blocks
      (when (= (block :type) "tool_use")
        (set stop-reason "tool_use")))
    (def response @{:role "assistant"
                    :content content-blocks
                    :stop_reason stop-reason
                    :type "message"})
    (when usage (put response :usage usage))
    response)

  @{:feed feed-line
    :finish finish
    :had-error (fn [] had-error)})

# ── Model listing ────────────────────────────────────────────

(def- known-models
  @[@{:id "gpt-5.1" :display_name "GPT-5.1"}
    @{:id "gpt-5.1-codex-max" :display_name "GPT-5.1 Codex Max"}
    @{:id "gpt-5.1-codex-mini" :display_name "GPT-5.1 Codex Mini"}
    @{:id "gpt-5.2" :display_name "GPT-5.2"}
    @{:id "gpt-5.2-codex" :display_name "GPT-5.2 Codex"}
    @{:id "gpt-5.3-codex" :display_name "GPT-5.3 Codex"}
    @{:id "gpt-5.3-codex-spark" :display_name "GPT-5.3 Codex Spark"}
    @{:id "gpt-5.4" :display_name "GPT-5.4"}])

(defn list-models [config]
  "Return known OpenAI models (static list)."
  known-models)

# ── Non-streaming body ───────────────────────────────────────

(defn build-body-no-stream [config conversation tools &opt system-prompt]
  "Build OpenAI Responses API request body without streaming. Returns JSON string."
  (def input (convert-messages-to-openai conversation))
  (def body @{:model (config :model)
              :store false
              :stream false
              :input input
              :tool_choice "auto"
              :parallel_tool_calls true})
  (when system-prompt
    (put body :instructions system-prompt))
  (when tools
    (put body :tools tools))
  (when (config :thinking-enabled)
    (put body :reasoning @{:effort "high" :summary "auto"})
    (put body :include @["reasoning.encrypted_content"]))
  (json/encode body))
