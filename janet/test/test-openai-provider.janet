# test-openai-provider.janet — Tests for the OpenAI Codex Responses API provider.

(import test/helper :as t)
(import core/providers/openai :as openai)
(import core/api :as api)
(import core/auth :as auth)

(print "── openai provider ──")

# ── Tool conversion ──────────────────────────────────────────

(t/test "convert-tools transforms canonical to OpenAI function format"
  (fn []
    (def tools @[{:name "bash"
                  :description "Run a bash command"
                  :input_schema {:type "object"
                                 :properties {:command {:type "string"}}
                                 :required ["command"]}}])
    (def converted (openai/convert-tools tools))
    (t/assert= 1 (length converted))
    (def tool (first converted))
    (t/assert= "function" (tool :type))
    (t/assert= "bash" (tool :name))
    (t/assert= "Run a bash command" (tool :description))
    (t/assert= "object" (get-in tool [:parameters :type]))))

(t/test "convert-tools handles multiple tools"
  (fn []
    (def tools @[{:name "a" :description "A" :input_schema {:type "object"}}
                 {:name "b" :description "B" :input_schema {:type "object"}}])
    (def converted (openai/convert-tools tools))
    (t/assert= 2 (length converted))
    (t/assert= "a" ((first converted) :name))
    (t/assert= "b" ((get converted 1) :name))))

# ── Headers ──────────────────────────────────────────────────

(t/test "build-headers includes Bearer token"
  (fn []
    (def headers (openai/build-headers @{:resolved-api-key "sk-test-key" :url "https://api.openai.com/v1/responses"}))
    (t/assert= "Bearer sk-test-key" (get headers "authorization"))
    (t/assert= "application/json" (get headers "content-type"))
    (t/assert= "text/event-stream" (get headers "accept"))))

# ── SSE parser: text response ────────────────────────────────

(t/test "parser handles text response"
  (fn []
    (var text-buf @"")
    (def parser (openai/new-stream-parser
                  @{:on-text (fn [t] (buffer/push text-buf t))}))

    # output_item.added (message)
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.added"
                                                     :output_index 0
                                                     :item @{:type "message" :id "msg_1"
                                                             :role "assistant"
                                                             :content @[]}})))
    # text delta
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_text.delta"
                                                     :output_index 0
                                                     :delta "Hello "})))
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_text.delta"
                                                     :output_index 0
                                                     :delta "world!"})))
    # output_item.done
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.done"
                                                     :output_index 0
                                                     :item @{:type "message" :id "msg_1"
                                                             :role "assistant"
                                                             :status "completed"
                                                             :content @[@{:type "output_text"
                                                                          :text "Hello world!"}]}})))
    # response.completed
    ((parser :feed) (string "data: " (json/encode @{:type "response.completed"
                                                     :response @{:status "completed"}})))

    (t/assert= "Hello world!" (string text-buf))
    (def result ((parser :finish)))
    (t/assert= "assistant" (result :role))
    (t/assert= "end_turn" (result :stop_reason))
    (t/assert= 1 (length (result :content)))
    (t/assert= "text" (get-in result [:content 0 :type]))
    (t/assert= "Hello world!" (get-in result [:content 0 :text]))))

# ── SSE parser: tool call response ───────────────────────────

(t/test "parser handles function call response"
  (fn []
    (var tool-started nil)
    (var tool-used nil)
    (def parser (openai/new-stream-parser
                  @{:on-tool-start (fn [name] (set tool-started name))
                    :on-tool-use (fn [id name input] (set tool-used @{:id id :name name :input input}))}))

    # function_call added
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.added"
                                                     :output_index 0
                                                     :item @{:type "function_call"
                                                             :call_id "call_123"
                                                             :name "bash"}})))
    (t/assert= "bash" tool-started)

    # arguments delta
    ((parser :feed) (string "data: " (json/encode @{:type "response.function_call_arguments.delta"
                                                     :output_index 0
                                                     :delta "{\"command\":\"ls\"}"})))

    # function_call done
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.done"
                                                     :output_index 0
                                                     :item @{:type "function_call"
                                                             :call_id "call_123"
                                                             :name "bash"
                                                             :arguments "{\"command\":\"ls\"}"}})))

    ((parser :feed) (string "data: " (json/encode @{:type "response.completed"
                                                     :response @{:status "completed"}})))

    (t/assert= "call_123" (tool-used :id))
    (t/assert= "bash" (tool-used :name))
    (t/assert= "ls" (get-in tool-used [:input :command]))

    (def result ((parser :finish)))
    (t/assert= "tool_use" (result :stop_reason))
    (t/assert= 1 (length (result :content)))
    (def block (first (result :content)))
    (t/assert= "tool_use" (block :type))
    (t/assert= "call_123" (block :id))
    (t/assert= "bash" (block :name))))

# ── SSE parser: error response ───────────────────────────────

(t/test "parser handles error response"
  (fn []
    (var error-msg nil)
    (def parser (openai/new-stream-parser
                  @{:on-error (fn [err] (set error-msg err))}))

    ((parser :feed) (string "data: " (json/encode @{:type "response.failed"
                                                     :response @{:error @{:message "rate limited"}}})))

    (t/assert= "rate limited" error-msg)
    (t/assert-truthy ((parser :had-error)))))

# ── SSE parser: reasoning/thinking ───────────────────────────

(t/test "parser handles reasoning with summary"
  (fn []
    (var thinking-buf @"")
    (def parser (openai/new-stream-parser
                  @{:on-thinking (fn [t] (buffer/push thinking-buf t))}))

    # reasoning item added
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.added"
                                                     :output_index 0
                                                     :item @{:type "reasoning"}})))
    # reasoning summary delta
    ((parser :feed) (string "data: " (json/encode @{:type "response.reasoning_summary_text.delta"
                                                     :output_index 0
                                                     :delta "Let me think..."})))

    # reasoning done with encrypted_content
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.done"
                                                     :output_index 0
                                                     :item @{:type "reasoning"
                                                             :encrypted_content "sig123"}})))

    # text response after reasoning
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.added"
                                                     :output_index 1
                                                     :item @{:type "message" :id "msg_1"
                                                             :role "assistant"
                                                             :content @[]}})))
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_text.delta"
                                                     :output_index 1
                                                     :delta "Answer"})))
    ((parser :feed) (string "data: " (json/encode @{:type "response.output_item.done"
                                                     :output_index 1
                                                     :item @{:type "message" :id "msg_1"
                                                             :content @[@{:type "output_text"
                                                                          :text "Answer"}]}})))

    ((parser :feed) (string "data: " (json/encode @{:type "response.completed"
                                                     :response @{:status "completed"}})))

    (t/assert= "Let me think..." (string thinking-buf))
    (def result ((parser :finish)))
    (t/assert= 2 (length (result :content)))
    (def thinking-block (first (result :content)))
    (t/assert= "thinking" (thinking-block :type))
    (t/assert= "Let me think..." (thinking-block :thinking))
    (t/assert= "sig123" (thinking-block :signature))))

# ── SSE parser: [DONE] marker ────────────────────────────────

(t/test "parser handles [DONE] marker"
  (fn []
    (def parser (openai/new-stream-parser @{}))
    ((parser :feed) "data: [DONE]")
    (def result ((parser :finish)))
    (t/assert= "assistant" (result :role))
    (t/assert-falsy ((parser :had-error)))))

# ── Model listing ────────────────────────────────────────────

(t/test "list-models returns static list"
  (fn []
    (def models (openai/list-models @{}))
    (t/assert-truthy (> (length models) 0))
    (def ids (map |($ :id) models))
    (t/assert-truthy (some |(= $ "gpt-5.1") ids))
    (t/assert-truthy (some |(= $ "gpt-5.1-codex-mini") ids))))

# ── Provider registration ────────────────────────────────────

(t/test "openai provider is registered in api"
  (fn []
    (def p (api/get-api-provider "openai"))
    (t/assert-truthy p)
    (t/assert= "OpenAI (Codex)" (p :name))
    (t/assert= "openai" (p :auth-provider))))

(t/test "set-provider to openai changes config"
  (fn []
    # Seed deterministic per-provider models first.
    (api/set-provider "anthropic")
    (api/set-model "claude-sonnet-4-20250514")
    (api/set-provider "openai")
    (api/set-model "gpt-5.1")

    # Switching back to openai should restore its model.
    (def cfg (api/get-config))
    (t/assert= "openai" (cfg :provider))
    (t/assert= "gpt-5.1" (cfg :model))

    # Switch back
    (api/set-provider "anthropic")
    (def cfg2 (api/get-config))
    (t/assert= "anthropic" (cfg2 :provider))
    (t/assert= "claude-sonnet-4-20250514" (cfg2 :model))))

(t/test "set-provider restores last model per provider"
  (fn []
    (api/set-provider "openai")
    (api/set-model "gpt-5.4")
    (t/assert= "gpt-5.4" (get (api/get-config) :model))

    (api/set-provider "anthropic")
    (t/assert= "claude-sonnet-4-20250514" (get (api/get-config) :model))
    (api/set-model "claude-opus-4-20250514")
    (t/assert= "claude-opus-4-20250514" (get (api/get-config) :model))

    (api/set-provider "openai")
    (t/assert= "gpt-5.4" (get (api/get-config) :model))

    (api/set-provider "anthropic")
    (t/assert= "claude-opus-4-20250514" (get (api/get-config) :model))))

(t/test "set-provider routes OpenAI api_key credentials to api.openai.com"
  (fn []
    (def old-cred (auth/get-credential "openai"))
    (def old-provider (api/get-active-provider-id))
    (defer
      (do
        (if old-cred
          (auth/set-credential "openai" old-cred)
          (auth/remove-credential "openai"))
        (when old-provider
          (api/set-provider old-provider))))
    (auth/set-credential "openai" @{"type" "api_key" "key" "sk-test-key"})
    (api/set-provider "openai")
    (t/assert= "https://api.openai.com/v1/responses" (get (api/get-config) :url))))

(t/test "set-provider routes OpenAI oauth credentials to ChatGPT Codex"
  (fn []
    (def old-cred (auth/get-credential "openai"))
    (def old-provider (api/get-active-provider-id))
    (defer
      (do
        (if old-cred
          (auth/set-credential "openai" old-cred)
          (auth/remove-credential "openai"))
        (when old-provider
          (api/set-provider old-provider))))
    (auth/set-credential "openai"
      @{"type" "oauth"
        "access" "eyJhbGciOiJSUzI1NiJ9.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF90ZXN0MTIzIn19.signature"
        "refresh" "rt"
        "expires" 9999999999999})
    (api/set-provider "openai")
    (t/assert= "https://chatgpt.com/backend-api/codex/responses" (get (api/get-config) :url))))

(t/test "set-provider rejects unknown provider"
  (fn []
    (var caught false)
    (try
      (api/set-provider "nonexistent")
      ([err] (set caught true)))
    (t/assert-truthy caught)))

# ── Request body ─────────────────────────────────────────────

(t/test "build-body includes instructions and tools"
  (fn []
    (def config @{:model "gpt-5.1" :thinking-enabled false :max-tokens 8192})
    (def conversation @[@{:role "user" :content "hello"}])
    (def tools @[@{:type "function" :name "bash" :description "Run command"
                   :parameters @{:type "object"}}])
    (def body-str (openai/build-body config conversation tools "Be helpful"))
    (def body (json/decode body-str))
    (t/assert= "gpt-5.1" (body :model))
    (t/assert-truthy (body :stream))
    (t/assert= "Be helpful" (body :instructions))
    (t/assert= 1 (length (body :tools)))
    (t/assert= 1 (length (body :input)))))

(t/test "build-body adds reasoning when thinking enabled"
  (fn []
    (def config @{:model "gpt-5.1" :thinking-enabled true :max-tokens 8192 :thinking-budget 4096})
    (def body-str (openai/build-body config @[] @[]))
    (def body (json/decode body-str))
    (t/assert-truthy (body :reasoning))
    (t/assert= "high" (get-in body [:reasoning :effort]))))

(t/test "build-body assistant message items do NOT include summary field"
  (fn []
    (def config @{:model "gpt-5.1" :thinking-enabled false :max-tokens 8192})
    (def conversation @[@{:role "user" :content "hello"}
                        @{:role "assistant"
                          :content @[@{:type "text" :text "Hi there!"}]}
                        @{:role "user" :content "thanks"}])
    (def body-str (openai/build-body config conversation @[]))
    (def body (json/decode body-str))
    (def input (body :input))
    # Find the message item (assistant response)
    (var msg-item nil)
    (each item input
      (when (= (get item :type) "message")
        (set msg-item item)))
    (t/assert-truthy msg-item)
    # Message items must NOT have summary (only reasoning items do)
    (t/assert-falsy (get msg-item :summary))))

(t/test "build-body reasoning items always have non-empty summary"
  (fn []
    (def config @{:model "gpt-5.1" :thinking-enabled true :max-tokens 8192 :thinking-budget 4096})
    (def conversation @[@{:role "user" :content "hello"}
                        @{:role "assistant"
                          :content @[@{:type "thinking" :thinking "" :signature "sig123"}
                                     @{:type "text" :text "result"}]}])
    (def body-str (openai/build-body config conversation @[]))
    (def body (json/decode body-str))
    (def input (body :input))
    # Find the reasoning item
    (var reasoning-item nil)
    (each item input
      (when (= (get item :type) "reasoning")
        (set reasoning-item item)))
    (t/assert-truthy reasoning-item)
    (t/assert-truthy (get reasoning-item :summary))
    # Summary must not be empty
    (t/assert-truthy (> (length (get reasoning-item :summary)) 0))
    (t/assert= "summary_text" (get-in reasoning-item [:summary 0 :type]))))

(t/test "build-body assistant tool_use message has no summary"
  (fn []
    (def config @{:model "gpt-5.1" :thinking-enabled false :max-tokens 8192})
    (def conversation @[@{:role "user" :content "run ls"}
                        @{:role "assistant"
                          :content @[@{:type "text" :text "I'll run that for you."}
                                     @{:type "tool_use" :id "call_1" :name "bash"
                                       :input @{:command "ls"}}]}])
    (def body-str (openai/build-body config conversation @[]))
    (def body (json/decode body-str))
    (def input (body :input))
    # Find all items
    (var msg-item nil)
    (var fc-item nil)
    (each item input
      (case (get item :type)
        "message" (set msg-item item)
        "function_call" (set fc-item item)))
    # Message should NOT have summary
    (t/assert-truthy msg-item)
    (t/assert-falsy (get msg-item :summary))
    # Function call should exist
    (t/assert-truthy fc-item)
    (t/assert= "bash" (get fc-item :name))))
