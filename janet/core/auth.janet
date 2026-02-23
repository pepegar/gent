# Authentication and credential storage for LLM providers.
#
# Stores credentials in ~/.gent/auth.json with file-level locking (rename-based).
# Supports:
#   - API keys (plain strings, env var references, or shell commands via "!" prefix)
#   - OAuth tokens (access + refresh + expiry, auto-refreshed)
#
# Priority for resolving an API key:
#   1. Runtime override (set via set-runtime-key)
#   2. auth.json (api_key or oauth credential)
#   3. Environment variable (provider-specific, e.g. ANTHROPIC_API_KEY)
#   4. Fallback resolver (user-defined function)
#
# Design inspired by pi-mono's auth-storage.ts but adapted for Janet/gent.

# ── Provider environment variable map ──────────────────────────────────
(def- env-key-map
  {"anthropic" ["ANTHROPIC_API_KEY" "GENT_API_KEY"]
   "openai" ["OPENAI_API_KEY"]
   "google" ["GEMINI_API_KEY"]
   "openrouter" ["OPENROUTER_API_KEY"]
   "xai" ["XAI_API_KEY"]
   "groq" ["GROQ_API_KEY"]
   "mistral" ["MISTRAL_API_KEY"]})

# ── URL encoding helper ───────────────────────────────────────────────
(defn- url-encode
  "URL-encode a string (percent-encode non-unreserved chars)."
  [s]
  (def buf @"")
  (each byte s
    (if (or (<= (chr "a") byte (chr "z"))
            (<= (chr "A") byte (chr "Z"))
            (<= (chr "0") byte (chr "9"))
            (= byte (chr "-"))
            (= byte (chr "_"))
            (= byte (chr "."))
            (= byte (chr "~")))
      (buffer/push-byte buf byte)
      (buffer/push buf (string/format "%%%02X" byte))))
  (string buf))

# ── OAuth provider registry ───────────────────────────────────────────
# Each provider is a table with:
#   :id         — string identifier (e.g. "anthropic")
#   :name       — human-readable name (e.g. "Anthropic (Claude Pro/Max)")
#   :login      — (fn [callbacks] => credentials) — run the OAuth flow
#   :refresh    — (fn [credentials] => credentials) — refresh expired tokens
#   :get-api-key — (fn [credentials] => string) — extract API key from credentials
(var- oauth-providers @{})

(defn register-oauth-provider
  "Register an OAuth provider. provider is a table with :id :name :login :refresh :get-api-key."
  [provider]
  (put oauth-providers (provider :id) provider))

(defn get-oauth-provider
  "Get an OAuth provider by ID, or nil."
  [id]
  (get oauth-providers id))

(defn get-oauth-providers
  "Get all registered OAuth providers as an array."
  []
  (values oauth-providers))

# ── Auth storage path ─────────────────────────────────────────────────
(def- gent-home
  (let [home (os/getenv "HOME")]
    (when home (string home "/.gent"))))

(def- auth-path
  (when gent-home (string gent-home "/auth.json")))

# ── Runtime state ─────────────────────────────────────────────────────
(var- runtime-overrides @{})
(var- auth-data @{})
(var- fallback-resolver nil)

# ── File I/O helpers ──────────────────────────────────────────────────
(defn- ensure-gent-dir []
  (when (and gent-home (not (os/stat gent-home)))
    (os/mkdir gent-home)))

(defn- stringify-keys
  "Recursively convert keyword keys to string keys in a table/struct."
  [val]
  (cond
    (or (table? val) (struct? val))
    (do
      (def result @{})
      (eachp [k v] val
        (def str-key (if (keyword? k) (string k) k))
        (put result str-key (stringify-keys v)))
      result)
    val))

(defn- read-auth-file []
  "Read and parse auth.json. Returns a table or empty table on error."
  (if (and auth-path (os/stat auth-path))
    (try
      (do
        (def content (slurp auth-path))
        (def parsed (json/decode content))
        (def tbl (if (table? parsed) parsed
                     (if (struct? parsed) (table ;(kvs parsed))
                         @{})))
        # json/decode uses keyword keys, but auth code expects string keys
        (stringify-keys tbl))
      ([err]
        (eprintf "Warning: failed to read auth.json: %s" (string err))
        @{}))
    @{}))

(defn- write-auth-file [data]
  "Write auth data to auth.json atomically (write to temp, rename)."
  (ensure-gent-dir)
  (when auth-path
    (def tmp-path (string auth-path ".tmp"))
    (try
      (do
        (spit tmp-path (json/encode data))
        # Rename for atomicity
        (os/rename tmp-path auth-path))
      ([err]
        (eprintf "Warning: failed to write auth.json: %s" (string err))
        # Clean up temp file if rename failed
        (when (os/stat tmp-path)
          (os/rm tmp-path))))))

# ── Config value resolution ───────────────────────────────────────────
# Similar to pi-mono's resolve-config-value:
#   "!" prefix → execute shell command, use stdout
#   Otherwise → check env var, then treat as literal
(defn- resolve-config-value [val]
  (cond
    (nil? val) nil
    (string/has-prefix? "!" val)
    (let [cmd (string/slice val 1)]
      (try
        (do
          (def result (process/exec "sh" ["-c" cmd]))
          (if (= 0 (result :status))
            (string/trim (result :stdout))
            nil))
        ([_] nil)))
    # Check if it's an env var name
    (let [env-val (os/getenv val)]
      (or env-val val))))

# ── Public API ────────────────────────────────────────────────────────

(defn reload
  "Reload credentials from auth.json."
  []
  (set auth-data (read-auth-file)))

(defn save
  "Persist current auth data to auth.json."
  []
  (write-auth-file auth-data))

(defn get-credential
  "Get the raw credential for a provider from auth.json. Returns table or nil."
  [provider]
  (get auth-data provider))

(defn set-credential
  "Set a credential for a provider and persist."
  [provider credential]
  (put auth-data provider credential)
  (save))

(defn remove-credential
  "Remove a credential for a provider and persist."
  [provider]
  (put auth-data provider nil)
  (save))

(defn has-credential?
  "Check if a credential exists for a provider in auth.json."
  [provider]
  (not (nil? (get auth-data provider))))

(defn list-providers
  "List all providers with stored credentials."
  []
  (keys auth-data))

(defn set-runtime-key
  "Set a runtime API key override (not persisted). Highest priority."
  [provider api-key]
  (put runtime-overrides provider api-key))

(defn remove-runtime-key
  "Remove a runtime API key override."
  [provider]
  (put runtime-overrides provider nil))

(defn set-fallback-resolver
  "Set a fallback resolver function (fn [provider] => key-or-nil)."
  [resolver]
  (set fallback-resolver resolver))

(defn get-env-key
  "Get API key from environment variables for a provider."
  [provider]
  (def env-vars (get env-key-map provider))
  (when env-vars
    (var result nil)
    (each var-name env-vars
      (when (nil? result)
        (set result (os/getenv var-name))))
    result))

(defn get-api-key
  ``Get the API key for a provider, checking all sources in priority order:
  1. Runtime override
  2. auth.json api_key credential
  3. auth.json oauth credential (with auto-refresh)
  4. Environment variable
  5. Fallback resolver

  Returns the key string or nil.
  ``
  [provider]
  # 1. Runtime override
  (def runtime-key (get runtime-overrides provider))
  (when runtime-key (break runtime-key))

  # 2. auth.json credential
  (def cred (get auth-data provider))
  (when cred
    (def cred-type (get cred "type" (get cred :type)))
    (cond
      (= cred-type "api_key")
      (do
        (def key-val (get cred "key" (get cred :key)))
        (when key-val
          (break (resolve-config-value key-val))))

      (= cred-type "oauth")
      (do
        (def oauth-provider (get-oauth-provider provider))
        (when oauth-provider
          (def expires (or (get cred "expires") (get cred :expires) 0))
          (def access (or (get cred "access") (get cred :access)))
          # Check if token needs refresh
          (if (> (os/time) (math/floor (/ expires 1000)))
            # Token expired — try to refresh
            (try
              (do
                (def refreshed ((oauth-provider :refresh) cred))
                (when refreshed
                  (def new-cred (merge cred refreshed))
                  (put new-cred "type" "oauth")
                  (set-credential provider new-cred)
                  (break ((oauth-provider :get-api-key) new-cred))))
              ([err]
                (eprintf "Warning: OAuth token refresh failed for %s: %s" provider (string err))
                nil))
            # Token still valid
            (break ((oauth-provider :get-api-key) cred)))))))

  # 3. Environment variable
  (def env-key (get-env-key provider))
  (when env-key (break env-key))

  # 4. Fallback resolver
  (when fallback-resolver
    (fallback-resolver provider)))

(defn has-auth?
  ``Check if any form of authentication is available for a provider.
  Unlike get-api-key, this doesn't refresh OAuth tokens.
  ``
  [provider]
  (or (not (nil? (get runtime-overrides provider)))
      (has-credential? provider)
      (not (nil? (get-env-key provider)))
      (and fallback-resolver (not (nil? (fallback-resolver provider))))))

# ── OAuth login/logout ────────────────────────────────────────────────

(defn login
  ``Run the OAuth login flow for a provider.

  callbacks is a table with:
    :on-auth     (fn [url &opt instructions]) — called with the auth URL to open
    :on-prompt   (fn [message] => string) — called to get user input
    :on-progress (fn [message]) — called with progress messages (optional)

  Returns the credentials on success, or throws on error.
  ``
  [provider-id callbacks]
  (def provider (get-oauth-provider provider-id))
  (unless provider
    (error (string "Unknown OAuth provider: " provider-id)))
  (def credentials ((provider :login) callbacks))
  (def cred-table (if (struct? credentials)
                    (table ;(kvs credentials))
                    credentials))
  (put cred-table "type" "oauth")
  (set-credential provider-id cred-table)
  cred-table)

(defn logout
  "Remove credentials for a provider."
  [provider-id]
  (remove-credential provider-id))

# ── Anthropic OAuth provider ─────────────────────────────────────────
# PKCE-based OAuth flow for Claude Pro/Max subscriptions.
# Uses the same client ID as pi-mono / Claude Code.

(defn generate-pkce
  "Generate PKCE code verifier and challenge using openssl. Returns {:verifier :challenge}."
  []
  # Generate 32 random bytes, base64url-encode as verifier
  (def verifier-result
    (process/exec "sh" ["-c" "openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\\n'"]))
  (when (not= 0 (verifier-result :status))
    (error "Failed to generate PKCE verifier"))
  (def verifier (string/trim (verifier-result :stdout)))

  # SHA-256 hash of verifier, base64url-encoded as challenge
  (def challenge-result
    (process/exec "sh" ["-c"
      (string "printf '%s' '" verifier "' | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\\n'")]))
  (when (not= 0 (challenge-result :status))
    (error "Failed to generate PKCE challenge"))
  (def challenge (string/trim (challenge-result :stdout)))

  {:verifier verifier :challenge challenge})

(def- anthropic-client-id "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
(def- anthropic-authorize-url "https://claude.ai/oauth/authorize")
(def- anthropic-token-url "https://console.anthropic.com/v1/oauth/token")
(def- anthropic-redirect-uri "https://console.anthropic.com/oauth/code/callback")
(def- anthropic-scopes "org:create_api_key user:profile user:inference")

(defn anthropic-auth-url
  "Build the Anthropic OAuth authorization URL from a PKCE pair."
  [pkce]
  (def auth-params
    (string "code=true"
            "&client_id=" anthropic-client-id
            "&response_type=code"
            "&redirect_uri=" (url-encode anthropic-redirect-uri)
            "&scope=" (url-encode anthropic-scopes)
            "&code_challenge=" (pkce :challenge)
            "&code_challenge_method=S256"
            "&state=" (pkce :verifier)))
  (string anthropic-authorize-url "?" auth-params))

(defn anthropic-exchange-code
  "Exchange an authorization code for tokens. Returns credential table.
   auth-code: the code#state string from the user.
   pkce: the {:verifier :challenge} from generate-pkce."
  [auth-code pkce]
  (when (or (nil? auth-code) (= "" (string/trim auth-code)))
    (error "No authorization code provided"))

  # Parse code#state format
  (def parts (string/split "#" (string/trim auth-code)))
  (def code (get parts 0))
  (def state (get parts 1))

  (def token-body
    (json/encode
      @{"grant_type" "authorization_code"
        "client_id" anthropic-client-id
        "code" code
        "state" (or state "")
        "redirect_uri" anthropic-redirect-uri
        "code_verifier" (pkce :verifier)}))

  (def response
    (http/request "POST" anthropic-token-url
      @{"content-type" "application/json"}
      token-body))

  (when (nil? response)
    (error "Token exchange failed — no response from Anthropic"))

  (def token-data (json/decode response))

  (when (or (nil? token-data) (nil? (get token-data :access_token)))
    (error (string "Token exchange failed: " (or response "unknown error"))))

  (def expires-in (get token-data :expires_in 3600))
  # Expiry: current time + expires_in seconds - 5 min buffer (in milliseconds for compat with pi-mono)
  (def expires-at (+ (* (os/time) 1000) (* expires-in 1000) (* -5 60 1000)))

  @{"type" "oauth"
    "refresh" (get token-data :refresh_token)
    "access" (get token-data :access_token)
    "expires" expires-at})

(defn- anthropic-login [callbacks]
  "Run the Anthropic OAuth PKCE flow (full flow with callbacks)."
  (def pkce (generate-pkce))
  (def auth-url (anthropic-auth-url pkce))

  # Notify caller to open the URL
  (when-let [on-auth (callbacks :on-auth)]
    (on-auth auth-url))

  # Prompt for authorization code
  (def on-prompt (callbacks :on-prompt))
  (unless on-prompt
    (error "OAuth login requires :on-prompt callback"))
  (def auth-code (on-prompt "Paste the authorization code:"))

  # Exchange code for tokens
  (when-let [on-progress (callbacks :on-progress)]
    (on-progress "Exchanging authorization code for tokens..."))

  (anthropic-exchange-code auth-code pkce))

(defn- anthropic-refresh [credentials]
  "Refresh Anthropic OAuth token."
  (def refresh-token (get credentials "refresh" (get credentials :refresh)))
  (unless refresh-token
    (error "No refresh token available"))

  (def body (json/encode
    @{"grant_type" "refresh_token"
      "client_id" anthropic-client-id
      "refresh_token" refresh-token}))

  (def response
    (http/request "POST" anthropic-token-url
      @{"content-type" "application/json"}
      body))

  (when (nil? response)
    (error "Anthropic token refresh failed — no response"))

  (def data (json/decode response))
  (when (or (nil? data) (nil? (get data :access_token)))
    (error (string "Anthropic token refresh failed: " (or response "unknown error"))))

  (def expires-in (get data :expires_in 3600))
  (def expires-at (+ (* (os/time) 1000) (* expires-in 1000) (* -5 60 1000)))

  @{"type" "oauth"
    "refresh" (or (get data :refresh_token) refresh-token)
    "access" (get data :access_token)
    "expires" expires-at})

(defn- anthropic-get-api-key [credentials]
  "Extract API key from Anthropic OAuth credentials."
  (get credentials "access" (get credentials :access)))

# Register the Anthropic OAuth provider
(register-oauth-provider
  @{:id "anthropic"
    :name "Anthropic (Claude Pro/Max)"
    :login anthropic-login
    :refresh anthropic-refresh
    :get-api-key anthropic-get-api-key})

# ── Initialize ────────────────────────────────────────────────────────
(reload)
