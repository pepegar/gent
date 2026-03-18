# Authentication slash commands — /login, /logout, /auth-status

(import core/commands :as commands)
(import core/auth :as auth)
(import core/api :as api)
(import core/selector :as selector)
(import widgets/editor :as editor-prompt)
(import widgets/chat :as chat)

# ── /login ─────────────────────────────────────────────────────

(defn- open-browser
  "Try to open a URL in the default browser. Fire-and-forget."
  [url]
  (def open-cmd
    (let [uname-result (process/exec "uname" ["-s"])]
      (if (= 0 (get uname-result :status))
        (case (string/trim (get uname-result :stdout ""))
          "Darwin" "open"
          "xdg-open")
        nil)))
  (when open-cmd
    (try
      (process/exec "sh" ["-c" (string open-cmd " '" url "' &")])
      ([_] nil))))

(defn- login-with-callback-server
  "Login flow using a local callback server (OpenAI-style).
   Starts a TCP listener, opens browser, polls for callback, falls back to manual paste."
  [provider-id provider pkce state auth-url]
  # Try to start local callback server
  (def listener-id
    (try (net/listen 1455) ([_] nil)))

  # Try to open browser
  (open-browser auth-url)

  (if listener-id
    (do
      # Poll for the callback — store state so the prompt callback can access it
      (var code nil)
      (var attempts 0)

      (while (and (nil? code) (< attempts 120))
        (set code (auth/openai-poll-callback listener-id state 500))
        (++ attempts))

      (net/close-listener listener-id)

      (if code
        (do
          # Exchange code for tokens
          (try
            (do
              (def credentials (auth/openai-exchange-code code pkce))
              (auth/set-credential provider-id credentials)
              (chat/output-info (string "✓ Logged in to " (provider :name))))
            ([err]
             (chat/output-error (string "Login failed: " (string err))))))
        (do
          # Timed out — fall back to manual prompt
          (editor-prompt/start-prompt
            {:label "code/url:"
             :mask false
             :callback
             (fn [input]
               (if (or (nil? input) (= "" (string/trim input)))
                 (chat/output-info "Login cancelled — no code provided.")
                 (try
                   (do
                     (var final-code nil)
                     (if (string/has-prefix? "http" input)
                       (do
                         (def parsed
                           (auth/openai-parse-http-request
                             (string "GET " (string/trim input) " HTTP/1.1")))
                         (when parsed
                           (set final-code (parsed :code))))
                       (set final-code (string/trim input)))
                     (if final-code
                       (do
                         (def credentials (auth/openai-exchange-code final-code pkce))
                         (auth/set-credential provider-id credentials)
                         (chat/output-info (string "✓ Logged in to " (provider :name))))
                       (chat/output-error "Could not extract authorization code from input.")))
                   ([err]
                    (chat/output-error (string "Login failed: " (string err)))))))}))))
    (do
      # Could not start server — manual paste only
      (editor-prompt/start-prompt
        {:label "code/url:"
         :mask false
         :callback
         (fn [input]
           (if (or (nil? input) (= "" (string/trim input)))
             (chat/output-info "Login cancelled — no code provided.")
             (try
               (do
                 (var final-code nil)
                 (if (string/has-prefix? "http" input)
                   (do
                     (def parsed
                       (auth/openai-parse-http-request
                         (string "GET " (string/trim input) " HTTP/1.1")))
                     (when parsed
                       (set final-code (parsed :code))))
                   (set final-code (string/trim input)))
                 (if final-code
                   (do
                     (def credentials (auth/openai-exchange-code final-code pkce))
                     (auth/set-credential provider-id credentials)
                     (chat/output-info (string "✓ Logged in to " (provider :name))))
                   (chat/output-error "Could not extract authorization code from input.")))
               ([err]
                (chat/output-error (string "Login failed: " (string err)))))))})))

  (string "Opening browser for " (provider :name) " login...\n"
          "\n"
          "  " auth-url "\n"
          "\n"
          (if listener-id
            "Waiting for browser callback..."
            "After authorizing, paste the redirect URL or code below and press Enter.\n(Press Escape to cancel)")))

(defn- login-with-manual-paste
  "Login flow using manual code paste (Anthropic-style).
   Opens browser, prompts user to paste authorization code."
  [provider-id provider pkce auth-url]
  # Try to open browser
  (open-browser auth-url)

  # Activate the inline prompt to collect the authorization code
  (editor-prompt/start-prompt
    {:label "token:"
     :mask false
     :callback
     (fn [code-input]
       (if (or (nil? code-input) (= "" (string/trim code-input)))
         (chat/output-info "Login cancelled — no code provided.")
         (try
           (do
             (def credentials (auth/anthropic-exchange-code code-input pkce))
             (auth/set-credential provider-id credentials)
             (chat/output-info (string "✓ Logged in to " (provider :name))))
           ([err]
            (chat/output-error (string "Login failed: " (string err)))))))})

  (string "Opening browser for " (provider :name) " login...\n"
          "\n"
          "  " auth-url "\n"
          "\n"
          "After authorizing, paste the code below and press Enter.\n"
          "(Press Escape to cancel)"))

(defn- list-oauth-providers []
  (sort-by |($ :id) (auth/get-oauth-providers)))

(defn- list-oauth-provider-ids []
  (map |($ :id) (list-oauth-providers)))

(defn- start-login-flow [provider-id provider]
  (try
    (do
      (def pkce (auth/generate-pkce))

      (case provider-id
        "openai"
        (do
          (def state (auth/openai-generate-state))
          (def auth-url (auth/openai-auth-url pkce state))
          (login-with-callback-server provider-id provider pkce state auth-url))

        # Default: Anthropic-style manual paste flow
        (do
          (def auth-url (auth/anthropic-auth-url pkce))
          (login-with-manual-paste provider-id provider pkce auth-url))))
    ([err]
     (string "✗ Login setup failed: " (string err)))))

(defn- open-login-selector []
  (def providers (list-oauth-providers))
  (if (empty? providers)
    "No OAuth providers registered."
    (do
      (def current-provider (api/get-active-provider-id))
      (selector/open
        {:title "Login"
         :items
         (map (fn [provider]
                (def id (provider :id))
                (def status
                  (if (auth/has-credential? id)
                    " · logged in"
                    ""))
                @{:id id
                  :label id
                  :detail (string (provider :name) status)
                  :search-text (string id " " (provider :name))
                  :current (= id current-provider)})
              providers)
         :empty-text "No OAuth providers available."
         :on-submit
         (fn [item]
           (def provider-id (item :id))
           (def result
             (start-login-flow provider-id (auth/get-oauth-provider provider-id)))
           (when (and result (not= "" result))
             (chat/output result)))})
      "")))

(commands/register "login"
  {:description "Login to an OAuth provider (e.g., /login anthropic)"
   :usage "/login [provider]"
   :function
   (fn [args]
     (def parts (string/split " " (string/trim args) 2))
     (def provider-id (get parts 0 ""))

     # If no provider specified, open the provider selector
     (when (= "" provider-id)
       (break (open-login-selector)))

     # Check if provider exists as OAuth
     (def provider (auth/get-oauth-provider provider-id))
     (unless provider
       # Maybe they want to set an API key directly?
       (break (string "Unknown OAuth provider: " provider-id
                      "\nAvailable: " (string/join (list-oauth-provider-ids) ", ")
                      "\n\nTo set an API key directly:\n"
                      "  /auth-key <provider> <key>")))

     (start-login-flow provider-id provider))})

# ── /logout ────────────────────────────────────────────────────

(commands/register "logout"
  {:description "Logout from a provider (e.g., /logout anthropic)"
   :usage "/logout [provider]"
   :function
   (fn [args]
     (def provider-id (string/trim args))

     (when (= "" provider-id)
       (def providers (auth/list-providers))
       (if (empty? providers)
         (break "No providers logged in.")
         (break
           (string "Logged in providers:\n"
                   (string/join
                     (seq [p :in providers]
                       (string "  • " p))
                     "\n")
                   "\n\nUsage: /logout <provider>"))))

     (if (auth/has-credential? provider-id)
       (do
         (auth/logout provider-id)
         (string "✓ Logged out from " provider-id))
       (string "Not logged in to " provider-id)))})

# ── /auth ──────────────────────────────────────────────────────

(commands/register "auth"
  {:description "Show authentication status for all providers"
   :usage "/auth"
   :function
   (fn [args]
     (def lines @["Authentication status:"])

     # Show OAuth providers
     (def oauth-providers (auth/get-oauth-providers))
     (each p oauth-providers
       (def pid (p :id))
       (def has-cred (auth/has-credential? pid))
       (def has-env (not (nil? (auth/get-env-key pid))))
       (def cred (auth/get-credential pid))
       (def cred-type (when cred (get cred "type" (get cred :type))))
       (def status
         (cond
           (and has-cred (= cred-type "oauth")) "✓ OAuth (auth.json)"
           (and has-cred (= cred-type "api_key")) "✓ API key (auth.json)"
           has-env "✓ env var"
           "✗ not configured"))
       (array/push lines (string "  " pid " (" (p :name) "): " status)))

     # Show any providers with env vars but no OAuth config
     (def env-only ["openai" "google" "openrouter" "xai" "groq" "mistral"])
     (each pid env-only
       (when (nil? (auth/get-oauth-provider pid))
         (def env-key (auth/get-env-key pid))
         (when env-key
           (array/push lines (string "  " pid ": ✓ env var")))))

     (when (= 1 (length lines))
       (array/push lines "  No authentication configured."))

     (string/join lines "\n"))})

# ── /auth-key ──────────────────────────────────────────────────

(commands/register "auth-key"
  {:description "Set an API key for a provider (e.g., /auth-key anthropic sk-...)"
   :usage "/auth-key <provider> <key>"
   :function
   (fn [args]
     (def parts (string/split " " (string/trim args) 2))
     (def provider-id (get parts 0 ""))
     (def api-key (get parts 1 ""))

     (when (or (= "" provider-id) (= "" api-key))
       (break "Usage: /auth-key <provider> <key>"))

     (auth/set-credential provider-id
       @{"type" "api_key"
         "key" api-key})

     (string "✓ API key saved for " provider-id))})
