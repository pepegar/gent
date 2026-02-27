# Authentication slash commands — /login, /logout, /auth-status

(import core/commands :as commands)
(import core/auth :as auth)
(import core/registers :as reg)
(import widgets/editor :as editor-prompt)
(import widgets/chat :as chat)

# ── /login ─────────────────────────────────────────────────────

(commands/register "login"
  {:description "Login to an OAuth provider (e.g., /login anthropic)"
   :usage "/login [provider]"
   :function
   (fn [args]
     (def parts (string/split " " (string/trim args) 2))
     (def provider-id (get parts 0 ""))

     # If no provider specified, list available ones
     (when (= "" provider-id)
       (def providers (auth/get-oauth-providers))
       (if (empty? providers)
         (break "No OAuth providers registered.")
         (break
           (string "Available OAuth providers:\n"
                   (string/join
                     (seq [p :in providers]
                       (def status
                         (if (auth/has-credential? (p :id))
                           " ✓ logged in"
                           ""))
                       (string "  • " (p :id) " — " (p :name) status))
                     "\n")
                   "\n\nUsage: /login <provider>"))))

     # Check if provider exists as OAuth
     (def provider (auth/get-oauth-provider provider-id))
     (unless provider
       # Maybe they want to set an API key directly?
       (break (string "Unknown OAuth provider: " provider-id
                      "\nAvailable: " (string/join (map |($ :id) (auth/get-oauth-providers)) ", ")
                      "\n\nTo set an API key directly:\n"
                      "  /auth-key <provider> <key>")))

     # Start the OAuth flow — generate PKCE, open browser, prompt for code
     (try
       (do
         (def pkce (auth/generate-pkce))
         (def url (auth/anthropic-auth-url pkce))

         # Try to open browser (fire-and-forget — don't block the TUI)
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
             ([_] nil)))

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
                 "  " url "\n"
                 "\n"
                 "After authorizing, paste the code below and press Enter.\n"
                 "(Press Escape to cancel)"))
       ([err]
        (string "✗ Login setup failed: " (string err)))))})

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
