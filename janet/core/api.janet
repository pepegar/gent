# Provider-agnostic API layer — delegates to the active provider backend.
# All HTTP is done via the native http/request function provided by Rust.
#
# Configuration priority for API keys:
#   1. Explicit set-api-key (runtime override via auth module)
#   2. GENT_API_KEY environment variable (explicit session override)
#   3. auth.json credential (API key or OAuth token, via auth module)
#   4. Provider-specific environment variable (e.g. ANTHROPIC_API_KEY)
#   5. Auth module fallback resolver
#
# Other configuration:
#   GENT_PROVIDER   — provider id (e.g. "openai", "anthropic")
#   GENT_API_URL    — API endpoint (default: from active provider)
#   GENT_MODEL      — model name
#   GENT_MAX_TOKENS — max tokens per response

(import core/auth :as auth)

# ── Config ───────────────────────────────────────────────────

# Mutable config — env vars override defaults, set-provider fills in the rest.
# Starts empty — no hardcoded provider. Auto-detected at the bottom of this file.
(var- config
  @{:url nil
    :model nil
    :max-tokens (let [env (os/getenv "GENT_MAX_TOKENS")]
                  (if env (scan-number env) 32000))
    :api-key nil  # nil means "resolve dynamically via auth module"
    :thinking-enabled true
    :thinking-budget 16000})

# ── Provider registry ────────────────────────────────────────

(var- providers @{})
(var- active-provider-id nil)
(var- provider-models @{})
(var- pending-env-model (os/getenv "GENT_MODEL"))

(def- openai-api-url "https://api.openai.com/v1/responses")
(def- openai-codex-url "https://chatgpt.com/backend-api/codex/responses")

(defn- openai-codex-token? [token]
  "Heuristically detect ChatGPT OAuth access tokens from their JWT shape."
  (and (string? token)
       (not (nil? (auth/openai-decode-jwt token)))))

(defn- resolve-provider-default-url [id p]
  "Resolve the provider URL, honoring explicit env overrides first."
  (when-let [env-url (os/getenv "GENT_API_URL")]
    (break env-url))
  (when (not= id "openai")
    (break (p :default-url)))

  # OpenAI supports both ChatGPT OAuth tokens and API keys.
  # Route API keys to api.openai.com and OAuth access tokens to ChatGPT Codex.
  (when-let [explicit-key (config :api-key)]
    (break (if (openai-codex-token? explicit-key) openai-codex-url openai-api-url)))
  (when-let [gent-key (os/getenv "GENT_API_KEY")]
    (break (if (openai-codex-token? gent-key) openai-codex-url openai-api-url)))

  (when-let [cred (auth/get-credential "openai")]
    (def cred-type (get cred "type" (get cred :type)))
    (break (if (= cred-type "oauth") openai-codex-url openai-api-url)))

  (when (auth/get-env-key "openai")
    (break openai-api-url))

  openai-codex-url)

(defn register-api-provider
  "Register an API provider backend. provider is a table with :id and provider functions."
  [provider]
  (put providers (provider :id) provider))

(defn get-api-provider
  "Get a provider by ID, or nil."
  [id]
  (get providers id))

(defn list-providers
  "Return registered providers sorted by ID."
  []
  (sort-by |($ :id) (values providers)))

(defn set-provider
  "Switch to a different API provider. Restores the provider's last model
   selection, or falls back to its default model the first time."
  [id]
  (def p (get providers id))
  (unless p (error (string "Unknown API provider: " id)))
  (set active-provider-id id)
  (put config :url (resolve-provider-default-url id p))
  (def model
    (cond
      (get provider-models id) (get provider-models id)
      pending-env-model
      (do
        (def env-model pending-env-model)
        (set pending-env-model nil)
        (put provider-models id env-model)
        env-model)
      true
      (do
        (put provider-models id (p :default-model))
        (p :default-model))))
  (put config :model model)
  (when (p :default-max-tokens)
    (put config :max-tokens (let [env (os/getenv "GENT_MAX_TOKENS")]
                              (if env (scan-number env) (p :default-max-tokens))))))

(defn get-active-provider
  "Return the active provider table."
  []
  (get providers active-provider-id))

(defn get-active-provider-id
  "Return the active provider ID string."
  []
  active-provider-id)

# ── Config setters ───────────────────────────────────────────

(defn set-url [url] (put config :url url))
(defn set-model [m]
  (put config :model m)
  (when active-provider-id
    (put provider-models active-provider-id m)))
(defn set-max-tokens [n] (put config :max-tokens n))
(defn set-thinking-enabled [v] (put config :thinking-enabled (truthy? v)))
(defn set-thinking-budget [n] (put config :thinking-budget n))

(defn set-api-key
  "Set an explicit API key. This takes highest priority.
   Also registers it as a runtime override in the auth module."
  [k]
  (put config :api-key k)
  # Also set it as a runtime override so auth/get-api-key returns it
  (def p (get-active-provider))
  (def auth-provider (or (when p (p :auth-provider)) "anthropic"))
  (auth/set-runtime-key auth-provider k))

(defn get-config
  "Return the current API configuration (for introspection)."
  []
  (def result (table/clone config))
  (def p (get-active-provider))
  (def auth-provider (or (when p (p :auth-provider)) "anthropic"))
  (put result :provider active-provider-id)
  # Resolve the effective API key for display (masked)
  (def effective-key (auth/get-api-key auth-provider))
  (when effective-key
    (put result :api-key-source
      (cond
        (config :api-key) "explicit (set-api-key)"
        (os/getenv "GENT_API_KEY") "GENT_API_KEY"
        (auth/has-credential? auth-provider) "auth.json"
        (os/getenv "OPENAI_API_KEY") "OPENAI_API_KEY"
        (os/getenv "ANTHROPIC_API_KEY") "ANTHROPIC_API_KEY"
        "unknown"))
    (put result :api-key
      (if (> (length effective-key) 12)
        (string (string/slice effective-key 0 8) "..." (string/slice effective-key -4))
        "****")))
  result)

(defn models-url
  "Derive the models list endpoint from the current API URL.
   Replaces the final path segment with 'models'."
  []
  (def url (config :url))
  (def parts (string/split "/" url))
  (put parts (- (length parts) 1) "models")
  (string/join parts "/"))

(defn- resolve-api-key []
  "Resolve the API key from all sources. Throws if none found."
  (def p (get-active-provider))
  (def auth-provider (or (when p (p :auth-provider)) "anthropic"))

  # 1. Explicit config (already registered as runtime override in auth)
  (when (config :api-key)
    (break (config :api-key)))

  # 2. GENT_API_KEY — explicit env var for this session
  (def gent-key (os/getenv "GENT_API_KEY"))
  (when gent-key (break gent-key))

  # 3-5. Auth module handles the full resolution chain
  (def key (auth/get-api-key auth-provider))
  (when key (break key))

  (error (string "No API key found for provider '" auth-provider "'. Options:\n"
                  "  • /login " auth-provider "     — OAuth login\n"
                  "  • Set the appropriate environment variable\n"
                  "  • (api/set-api-key k)  — set in init.janet")))

# ── Provider-delegating functions ────────────────────────────

(defn- resolve-config []
  "Build the full config table with resolved API key for provider functions."
  (def resolved @{})
  (eachp [k v] config (put resolved k v))
  (put resolved :resolved-api-key (resolve-api-key))
  resolved)

(defn force-refresh-auth
  "Force-refresh the OAuth token for the active provider.
   Returns true if a new token was obtained, false otherwise."
  []
  (def p (get-active-provider))
  (def auth-provider (or (when p (p :auth-provider)) "anthropic"))
  (not (nil? (auth/force-refresh auth-provider))))

(defn list-models
  "Fetch available models from the active provider."
  []
  (def p (get-active-provider))
  (when (and p (p :list-models))
    (break ((p :list-models) (resolve-config))))
  nil)

(defn new-stream-parser
  ``Create a new SSE stream parser using the active provider's parser.

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
  (def p (get-active-provider))
  (when (and p (p :new-stream-parser))
    (break ((p :new-stream-parser) callbacks)))
  (error "No active provider or provider has no stream parser"))

(defn stream-start
  ``Start a non-blocking streaming request to the active provider.

  Returns a table with:
    :parser     — the SSE stream parser (feed lines with (:feed parser line))
    :stream-id  — the stream ID for http/stream-read and http/stream-stop

  Use http/stream-read to get lines, feed them to the parser.
  Call (:finish (:parser result)) when done to get the response.
  ``
  [conversation tools callbacks &opt system-prompt]
  (def p (get-active-provider))
  (unless p (error "No active API provider"))
  (def resolved (resolve-config))
  (def headers ((p :build-headers) resolved))
  (def converted-tools (if (p :convert-tools) ((p :convert-tools) tools) tools))
  (def body ((p :build-body) resolved conversation converted-tools system-prompt))
  (def parser ((p :new-stream-parser) callbacks))

  # Start the background HTTP stream — returns a stream-id
  (def stream-id (http/stream-start "POST" (config :url) headers body))

  @{:parser parser :stream-id stream-id})

(defn chat
  "Send a conversation to the active provider (non-streaming)."
  [conversation tools &opt system-prompt]
  (def p (get-active-provider))
  (unless p (error "No active API provider"))
  (def resolved (resolve-config))
  (def headers ((p :build-headers) resolved))
  (def converted-tools (if (p :convert-tools) ((p :convert-tools) tools) tools))
  (def body
    (if (p :build-body-no-stream)
      ((p :build-body-no-stream) resolved conversation converted-tools system-prompt)
      # Fallback: use streaming body builder (some providers only have one)
      ((p :build-body) resolved conversation converted-tools system-prompt)))
  (def response (http/request "POST" (config :url) headers body))
  (when (nil? response)
    (error "API request failed — got nil response"))
  (json/decode response))

(defn chat-stream
  ``Send a conversation with SSE streaming (blocking).

  callbacks: a table of callback functions:
    :on-text      (fn [text])           — called with each text delta
    :on-thinking  (fn [text])           — called with each thinking delta (optional)
    :on-tool-use  (fn [id name input])  — called when a tool_use block is complete
    :on-done      (fn [response])       — called with the reconstructed full response
    :on-error     (fn [err])            — called on error

  Returns the full reconstructed response (same shape as non-streaming chat).
  ``
  [conversation tools callbacks &opt system-prompt]
  (def p (get-active-provider))
  (unless p (error "No active API provider"))
  (def resolved (resolve-config))
  (def headers ((p :build-headers) resolved))
  (def converted-tools (if (p :convert-tools) ((p :convert-tools) tools) tools))
  (def body ((p :build-body) resolved conversation converted-tools system-prompt))
  (def parser ((p :new-stream-parser) callbacks))

  (def result
    (try
      (http/stream "POST" (config :url) headers body (fn [line] ((parser :feed) line)))
      ([err]
       (when-let [cb (get callbacks :on-error)]
         (cb (string err)))
       nil)))

  (def response ((parser :finish)))

  (when-let [cb (get callbacks :on-done)]
    (cb response))

  response)

# ── Register built-in Anthropic provider ─────────────────────

(import core/providers/anthropic :as anthropic)

(register-api-provider
  @{:id "anthropic"
    :name "Anthropic"
    :auth-provider "anthropic"
    :default-url "https://api.anthropic.com/v1/messages"
    :default-model "claude-sonnet-4-20250514"
    :default-max-tokens 32000
    :build-headers anthropic/build-headers
    :convert-tools anthropic/convert-tools
    :build-body anthropic/build-body
    :build-body-no-stream anthropic/build-body-no-stream
    :new-stream-parser anthropic/new-stream-parser
    :list-models anthropic/list-models})

# ── Register built-in OpenAI provider ────────────────────────

(import core/providers/openai :as openai)

(register-api-provider
  @{:id "openai"
    :name "OpenAI (Codex)"
    :auth-provider "openai"
    :default-url "https://chatgpt.com/backend-api/codex/responses"
    :default-model "gpt-5.1"
    :default-max-tokens 16384
    :build-headers openai/build-headers
    :convert-tools openai/convert-tools
    :build-body openai/build-body
    :build-body-no-stream openai/build-body-no-stream
    :new-stream-parser openai/new-stream-parser
    :list-models openai/list-models})

# ── Auto-detect active provider ──────────────────────────────
# Priority: GENT_PROVIDER env var → first provider with auth → first registered.
# Must run after all providers are registered and auth.janet has loaded credentials.

(defn- detect-provider []
  "Auto-detect which provider to use based on env and auth state."
  # 1. Explicit env var
  (when-let [env-provider (os/getenv "GENT_PROVIDER")]
    (break env-provider))
  # 2. First provider that has authentication configured
  (var found nil)
  (eachp [id p] providers
    (when (and (nil? found) (auth/has-auth? (p :auth-provider)))
      (set found id)))
  (when found (break found))
  # 3. First registered provider (arbitrary but stable)
  (when (> (length providers) 0)
    (break (first (keys providers))))
  nil)

(when-let [provider-id (detect-provider)]
  (set-provider provider-id))
