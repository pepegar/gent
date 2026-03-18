# test/test-auth.janet — Tests for OpenAI OAuth provider in core/auth.

(import test/helper :as t)
(import test/fake-http :as fake)

(import core/auth :as auth)
(import core/api :as api)
(import core/commands :as commands)
(import core/selector :as selector)
(import core/widget :as widget)
(import widgets/chat :as chat)
(import widgets/editor :as editor)
(import commands/auth)

(print "── test-auth ──")

(defn- setup-auth-command-ui []
  (chat/reset-state)
  (selector/reset-state)
  (editor/cancel-prompt)
  (each name (widget/list-widgets)
    (widget/unregister name))
  (widget/register (chat/create))
  (widget/register (editor/create))
  (api/set-provider "anthropic"))

# ── URL encoding ─────────────────────────────────────────────────

(t/test "openai-auth-url builds correct URL with all params"
  (fn []
    (def pkce {:verifier "test-verifier" :challenge "test-challenge"})
    (def state "abc123def456")
    (def url (auth/openai-auth-url pkce state))
    (t/assert-truthy (string/has-prefix? "https://auth.openai.com/oauth/authorize?" url))
    (t/assert-truthy (string/find "response_type=code" url))
    (t/assert-truthy (string/find "client_id=app_EMoamEEZ73f0CkXaXp7hrann" url))
    (t/assert-truthy (string/find "code_challenge=test-challenge" url))
    (t/assert-truthy (string/find "code_challenge_method=S256" url))
    (t/assert-truthy (string/find (string "state=" state) url))
    (t/assert-truthy (string/find "codex_cli_simplified_flow=true" url))
    (t/assert-truthy (string/find "originator=gent" url))
    (t/assert-truthy (string/find "id_token_add_organizations=true" url))))

# ── JWT decode ───────────────────────────────────────────────────

(t/test "openai-decode-jwt extracts accountId from a sample JWT"
  (fn []
    # Construct a fake JWT with the expected claim structure
    # Payload: {"https://api.openai.com/auth": {"chatgpt_account_id": "acct_test123"}}
    # Base64url-encoded payload
    (fake/set-process-handler
      (fn [cmd args]
        # The JWT decode calls base64 -d via shell
        (if (and (= cmd "sh")
                 (string/find "base64" (get args 1 "")))
          @{:stdout `{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_test123"}}`
            :stderr ""
            :status 0}
          @{:stdout "" :stderr "" :status 0})))

    # Create a JWT with a valid structure (header.payload.signature)
    # We just need the second segment to be base64url-decodable
    (def fake-jwt "eyJhbGciOiJSUzI1NiJ9.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF90ZXN0MTIzIn19.signature")
    (def account-id (auth/openai-decode-jwt fake-jwt))
    (t/assert= "acct_test123" account-id)

    (fake/set-process-handler nil)))

(t/test "openai-decode-jwt returns nil for invalid JWT"
  (fn []
    (fake/set-process-handler
      (fn [cmd args]
        @{:stdout "" :stderr "error" :status 1}))
    (def result (auth/openai-decode-jwt "not-a-jwt"))
    (t/assert-falsy result)
    (fake/set-process-handler nil)))

# ── HTTP request parsing ─────────────────────────────────────────

(t/test "openai-parse-http-request extracts code and state"
  (fn []
    (def raw "GET /auth/callback?code=abc123&state=xyz789 HTTP/1.1\r\nHost: localhost:1455\r\n\r\n")
    (def result (auth/openai-parse-http-request raw))
    (t/assert= "abc123" (result :code))
    (t/assert= "xyz789" (result :state))))

(t/test "openai-parse-http-request returns nil for missing params"
  (fn []
    (def raw "GET /auth/callback HTTP/1.1\r\nHost: localhost\r\n\r\n")
    (def result (auth/openai-parse-http-request raw))
    (t/assert-falsy result)))

(t/test "openai-parse-http-request returns nil for non-GET"
  (fn []
    (def raw "POST /auth/callback?code=abc&state=xyz HTTP/1.1\r\n\r\n")
    (def result (auth/openai-parse-http-request raw))
    (t/assert-falsy result)))

(t/test "openai-parse-http-request returns nil for nil input"
  (fn []
    (def result (auth/openai-parse-http-request nil))
    (t/assert-falsy result)))

# ── Token exchange (mocked HTTP) ─────────────────────────────────

(t/test "openai-exchange-code sends form-encoded POST and parses response"
  (fn []
    (fake/set-process-handler
      (fn [cmd args]
        # JWT decode for accountId extraction
        (if (and (= cmd "sh")
                 (string/find "base64" (get args 1 "")))
          @{:stdout `{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_abc"}}`
            :stderr ""
            :status 0}
          @{:stdout "" :stderr "" :status 0})))

    # Use a JWT-shaped token (header.payload.signature) so decode-jwt doesn't bail early
    (fake/queue-request-response
      (json/encode @{:access_token "eyJhbGciOiJSUzI1NiJ9.eyJ0ZXN0IjoidHJ1ZSJ9.sig"
                     :refresh_token "rt_test"
                     :expires_in 3600}))

    (def pkce {:verifier "test-verifier" :challenge "test-challenge"})
    (def cred (auth/openai-exchange-code "authcode123" pkce))

    # Verify credential structure
    (t/assert= "oauth" (get cred "type"))
    (t/assert= "eyJhbGciOiJSUzI1NiJ9.eyJ0ZXN0IjoidHJ1ZSJ9.sig" (get cred "access"))
    (t/assert= "rt_test" (get cred "refresh"))
    (t/assert= "acct_abc" (get cred "accountId"))
    (t/assert-truthy (get cred "expires"))

    # Verify the request was form-encoded
    (def req (fake/get-last-request))
    (t/assert= "POST" (req :method))
    (t/assert= "https://auth.openai.com/oauth/token" (req :url))
    (t/assert= "application/x-www-form-urlencoded" (get (req :headers) "content-type"))
    (t/assert-truthy (string/find "grant_type=authorization_code" (req :body)))
    (t/assert-truthy (string/find "code=authcode123" (req :body)))
    (t/assert-truthy (string/find "code_verifier=test-verifier" (req :body)))

    (fake/set-process-handler nil)))

# ── Token refresh (mocked HTTP) ──────────────────────────────────

(t/test "openai refresh token sends form-encoded POST"
  (fn []
    (fake/set-process-handler
      (fn [cmd args]
        (if (and (= cmd "sh")
                 (string/find "base64" (get args 1 "")))
          @{:stdout `{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_refreshed"}}`
            :stderr ""
            :status 0}
          @{:stdout "" :stderr "" :status 0})))

    # Use a JWT-shaped token so decode-jwt processes it
    (fake/queue-request-response
      (json/encode @{:access_token "eyJhbGciOiJSUzI1NiJ9.eyJuZXciOiJ0cnVlIn0.newsig"
                     :refresh_token "new_rt"
                     :expires_in 7200}))

    # Get the provider and call refresh directly
    (def provider (auth/get-oauth-provider "openai"))
    (def old-cred @{"type" "oauth"
                    "access" "old_at"
                    "refresh" "old_rt"
                    "expires" 0})
    (def new-cred ((provider :refresh) old-cred))

    (t/assert= "eyJhbGciOiJSUzI1NiJ9.eyJuZXciOiJ0cnVlIn0.newsig" (get new-cred "access"))
    (t/assert= "new_rt" (get new-cred "refresh"))
    (t/assert= "acct_refreshed" (get new-cred "accountId"))

    # Verify request was form-encoded with refresh_token grant
    (def req (fake/get-last-request))
    (t/assert-truthy (string/find "grant_type=refresh_token" (req :body)))
    (t/assert-truthy (string/find "refresh_token=old_rt" (req :body)))

    (fake/set-process-handler nil)))

# ── Provider registration ────────────────────────────────────────

(t/test "openai provider is registered"
  (fn []
    (def provider (auth/get-oauth-provider "openai"))
    (t/assert-truthy provider)
    (t/assert= "openai" (provider :id))
    (t/assert= "OpenAI (ChatGPT Plus/Pro)" (provider :name))))

(t/test "/login with no args opens selector"
  (fn []
    (setup-auth-command-ui)
    (def result (commands/dispatch "/login"))
    (def items (selector/get-filtered))
    (def anthropic-item (find |(= ($ :id) "anthropic") items))
    (t/assert-truthy (get result :handled))
    (t/assert= (get result :result) "")
    (t/assert-truthy (selector/active?))
    (t/assert= (length items) 2)
    (t/assert= (get (selector/get-selected) :id) "anthropic")
    (t/assert-truthy (get anthropic-item :current false))
    (selector/close)))

(t/test "/login selector enter starts selected provider flow"
  (fn []
    (setup-auth-command-ui)
    (commands/dispatch "/login")
    (selector/handle-key {:key :enter})
    (t/assert-falsy (selector/active?))
    (t/assert-truthy (editor/prompt-active?))
    (t/assert-truthy
      (find |(string/find "Opening browser for Anthropic" (get $ :text ""))
            (chat/get-scrollback)))
    (editor/cancel-prompt)))

(t/test "get-api-key extracts access token from openai credentials"
  (fn []
    (def provider (auth/get-oauth-provider "openai"))
    (def cred @{"type" "oauth" "access" "my-token" "refresh" "rt" "expires" 999999999999})
    (def key ((provider :get-api-key) cred))
    (t/assert= "my-token" key)))

(t/test "openai-get-account-id extracts accountId"
  (fn []
    (def cred @{"accountId" "acct_xyz"})
    (t/assert= "acct_xyz" (auth/openai-get-account-id cred))))

(t/test "reload loads credentials from auth.json in isolated HOME"
  (fn []
    (def home (os/getenv "HOME"))
    (def gent-dir (string home "/.gent"))
    (def auth-path (string gent-dir "/auth.json"))
    (def old-content (when (os/stat auth-path) (slurp auth-path)))
    (defer
      (do
        (if old-content
          (spit auth-path old-content)
          (when (os/stat auth-path)
            (os/rm auth-path)))
        (auth/reload)))
    (when (not (os/stat gent-dir))
      (os/mkdir gent-dir))
    (spit auth-path "{\"openai\":{\"type\":\"api_key\",\"key\":\"sk-from-disk\"}}")
    (auth/reload)
    (def cred (auth/get-credential "openai"))
    (t/assert= "api_key" (get cred "type"))
    (t/assert= "sk-from-disk" (get cred "key"))))

(t/test "login preserves struct credentials before persisting"
  (fn []
    (def provider-id "openai")
    (def provider (auth/get-oauth-provider provider-id))
    (def old-login (provider :login))
    (def old-cred (auth/get-credential provider-id))
    (defer
      (do
        (put provider :login old-login)
        (if old-cred
          (auth/set-credential provider-id old-cred)
          (auth/remove-credential provider-id))
        (auth/reload)))
    (put provider :login
         (fn [_]
           {:access "struct-access"
            :refresh "struct-refresh"
            :expires 12345}))
    (def cred (auth/login provider-id @{}))
    (t/assert= "oauth" (get cred "type"))
    (t/assert= "struct-access" (get cred "access"))
    (t/assert= "struct-refresh" (get cred "refresh"))
    (auth/reload)
    (def stored (auth/get-credential provider-id))
    (t/assert= "oauth" (get stored "type"))
    (t/assert= "struct-access" (get stored "access"))
    (t/assert= "struct-refresh" (get stored "refresh"))))

# ── Callback server polling (mocked net) ─────────────────────────

(t/test "openai-poll-callback returns code on valid request"
  (fn []
    (fake/net-reset)
    (def listener-id (net/listen 1455))

    # Inject a connection with a valid HTTP request
    (def request-data
      "GET /auth/callback?code=testcode&state=teststate HTTP/1.1\r\nHost: localhost:1455\r\n\r\n")
    (fake/net-inject-connection listener-id @[request-data])

    (def code (auth/openai-poll-callback listener-id "teststate" 100))
    (t/assert= "testcode" code)

    (net/close-listener listener-id)
    (fake/net-reset)))

(t/test "openai-poll-callback returns nil on state mismatch"
  (fn []
    (fake/net-reset)
    (def listener-id (net/listen 1455))

    (def request-data
      "GET /auth/callback?code=testcode&state=wrongstate HTTP/1.1\r\nHost: localhost:1455\r\n\r\n")
    (fake/net-inject-connection listener-id @[request-data])

    (def code (auth/openai-poll-callback listener-id "expected-state" 100))
    (t/assert-falsy code)

    (net/close-listener listener-id)
    (fake/net-reset)))

(t/test "openai-poll-callback returns nil when no connection"
  (fn []
    (fake/net-reset)
    (def listener-id (net/listen 1455))

    (def code (auth/openai-poll-callback listener-id "teststate" 100))
    (t/assert-falsy code)

    (net/close-listener listener-id)
    (fake/net-reset)))
