# Authentication slash commands — /login, /logout, /auth-status

(import core/commands :as commands)
(import core/auth :as auth)
(import core/registers :as reg)

# ── /login ─────────────────────────────────────────────────────

(commands/register "login"
  {:description "Login to an OAuth provider (e.g., /login anthropic)"
   :usage "/login [provider] [code]"
   :function
   (fn [args]
     (def parts (string/split " " (string/trim args) 2))
     (def provider-id (get parts 0 ""))
     (def code-arg (get parts 1 ""))

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

     # If code is provided, complete the flow (step 2)
     (when (not= "" code-arg)
       (def pending (reg/get :pending-login))
       (when (or (nil? pending) (not= (pending :provider) provider-id))
         (break (string "No pending login for " provider-id ". Run /login " provider-id " first.")))

       (try
         (do
           (def credentials (auth/anthropic-exchange-code code-arg (pending :pkce)))
           (auth/set-credential provider-id credentials)
           (reg/set :pending-login nil)
           (string "✓ Logged in to " (provider :name)))
         ([err]
           (reg/set :pending-login nil)
           (string "✗ Login failed: " (string err)))))

     # Step 1: Start the OAuth flow — show URL, ask for code
     (try
       (do
         (var auth-url nil)
         # Generate PKCE and get the auth URL by calling the provider's login
         # with a callback that captures the URL but returns a special code
         # to indicate we're in step 1
         #
         # Actually, we need to split the login flow. The auth module's login
         # function does the full flow in one shot. For the TUI, we need to
         # generate the URL, show it, and then wait for the user to come back
         # with /login provider <code>.
         #
         # For Anthropic specifically, we can generate the PKCE + URL here,
         # stash the verifier, and complete when the user provides the code.

         (def pkce (auth/generate-pkce))
         (def url (auth/anthropic-auth-url pkce))
         (reg/set :pending-login @{:provider provider-id :pkce pkce})

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
             # Use sh -c with & to avoid blocking on the browser
             (process/exec "sh" ["-c" (string open-cmd " '" url "' &")])
             ([_] nil)))

         (string "Opening browser for " (provider :name) " login...\n"
                 "\n"
                 "  " url "\n"
                 "\n"
                 "After authorizing, paste the code:\n"
                 "  /login " provider-id " <paste-code-here>"))
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
