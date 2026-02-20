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

# TODO: chat-stream variant for SSE streaming
# Will use http/stream-to (the async native) + ev/chan
# For now, non-streaming chat works for the scaffolding.
