# test/test-token-refresh.janet — Tests for OAuth token refresh logic in auth.janet.
#
# Verifies:
#   - Anthropic token refresh success/failure
#   - OpenAI token refresh success/failure
#   - Token expiry detection triggers auto-refresh in get-api-key
#   - Valid tokens are returned without refresh
#   - force-refresh ignores expiry and always refreshes

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/auth :as auth)
(import test/helper :as t)

(print "── test-token-refresh ──")

# ── Helper: save/restore auth state ──────────────────────────

(defn- with-clean-auth [f]
  "Run f with a clean auth state, restoring afterwards."
  (auth/remove-credential "anthropic")
  (auth/remove-credential "openai")
  (auth/remove-runtime-key "anthropic")
  (auth/remove-runtime-key "openai")
  (fake/reset)
  (fake/set-process-handler nil)
  (f)
  (auth/remove-credential "anthropic")
  (auth/remove-credential "openai")
  (auth/remove-runtime-key "anthropic")
  (auth/remove-runtime-key "openai")
  (fake/set-process-handler nil))

# ── Anthropic token refresh ──────────────────────────────────

(t/test "Anthropic token refresh success"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "old-access-token"
            "refresh" "test-refresh-token"
            "expires" 0})

        (fake/queue-request-response
          (json/encode @{:access_token "fresh-access-token"
                         :refresh_token "fresh-refresh-token"
                         :expires_in 3600}))

        (def result (auth/force-refresh "anthropic"))
        (t/assert-truthy result)
        (t/assert= "fresh-access-token" result)

        (def req (fake/get-last-request))
        (t/assert= "POST" (req :method))
        (t/assert-truthy (string/find "oauth/token" (req :url)))

        (def stored (auth/get-credential "anthropic"))
        (t/assert= "fresh-access-token" (get stored "access"))
        (t/assert= "fresh-refresh-token" (get stored "refresh"))
        (t/assert= "oauth" (get stored "type"))))))

(t/test "Anthropic token refresh failure — nil HTTP response"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "old-access"
            "refresh" "old-refresh"
            "expires" 0})

        # No queued response → http/request returns nil → refresh throws → force-refresh catches
        (def result (auth/force-refresh "anthropic"))
        (t/assert-falsy result)))))

(t/test "Anthropic token refresh failure — bad JSON response"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "old-access"
            "refresh" "old-refresh"
            "expires" 0})

        (fake/queue-request-response "not valid json {{{")

        (def result (auth/force-refresh "anthropic"))
        (t/assert-falsy result)))))

(t/test "Anthropic token refresh failure — response missing access_token"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "old-access"
            "refresh" "old-refresh"
            "expires" 0})

        (fake/queue-request-response
          (json/encode @{:error "invalid_grant"}))

        (def result (auth/force-refresh "anthropic"))
        (t/assert-falsy result)))))

# ── OpenAI token refresh ─────────────────────────────────────

(t/test "OpenAI token refresh success"
  (fn []
    (with-clean-auth
      (fn []
        (fake/set-process-handler
          (fn [cmd args]
            (if (and (= cmd "sh")
                     (string/find "base64" (get args 1 "")))
              @{:stdout `{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_refreshed"}}`
                :stderr ""
                :status 0}
              @{:stdout "" :stderr "" :status 0})))

        (auth/set-credential "openai"
          @{"type" "oauth"
            "access" "old-openai-access"
            "refresh" "openai-refresh-token"
            "expires" 0})

        (fake/queue-request-response
          (json/encode @{:access_token "eyJhbGciOiJSUzI1NiJ9.eyJ0ZXN0IjoidHJ1ZSJ9.sig"
                         :refresh_token "new-openai-refresh"
                         :expires_in 7200}))

        (def result (auth/force-refresh "openai"))
        (t/assert-truthy result)
        (t/assert= "eyJhbGciOiJSUzI1NiJ9.eyJ0ZXN0IjoidHJ1ZSJ9.sig" result)

        (def req (fake/get-last-request))
        (t/assert= "POST" (req :method))
        (t/assert-truthy (string/find "grant_type=refresh_token" (req :body)))
        (t/assert-truthy (string/find "refresh_token=openai-refresh-token" (req :body)))

        (def stored (auth/get-credential "openai"))
        (t/assert= "eyJhbGciOiJSUzI1NiJ9.eyJ0ZXN0IjoidHJ1ZSJ9.sig" (get stored "access"))
        (t/assert= "new-openai-refresh" (get stored "refresh"))))))

(t/test "OpenAI token refresh failure — nil response"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "openai"
          @{"type" "oauth"
            "access" "old-access"
            "refresh" "old-refresh"
            "expires" 0})

        (def result (auth/force-refresh "openai"))
        (t/assert-falsy result)))))

# ── force-refresh with no credential ─────────────────────────

(t/test "force-refresh returns nil when no credential exists"
  (fn []
    (with-clean-auth
      (fn []
        (def result (auth/force-refresh "anthropic"))
        (t/assert-falsy result)))))

(t/test "force-refresh returns nil for api_key credential (not oauth)"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "api_key"
            "key" "sk-ant-test123"})
        (def result (auth/force-refresh "anthropic"))
        (t/assert-falsy result)))))

# ── Token expiry detection in get-api-key ────────────────────

(t/test "get-api-key auto-refreshes expired oauth token and updates credential"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "expired-token"
            "refresh" "my-refresh-token"
            "expires" 1000})

        (fake/queue-request-response
          (json/encode @{:access_token "auto-refreshed-token"
                         :refresh_token "new-refresh"
                         :expires_in 3600}))

        (auth/get-api-key "anthropic")

        (def req (fake/get-last-request))
        (t/assert= "POST" (req :method))
        (t/assert-truthy (string/find "refresh_token" (req :body)))

        (def stored (auth/get-credential "anthropic"))
        (t/assert= "auto-refreshed-token" (get stored "access"))
        (t/assert= "new-refresh" (get stored "refresh"))))))

(t/test "get-api-key returns existing token when not expired"
  (fn []
    (with-clean-auth
      (fn []
        # Set an OAuth credential with far-future expiry (in milliseconds)
        (def far-future (* (+ (os/time) 99999) 1000))
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "valid-token"
            "refresh" "my-refresh-token"
            "expires" far-future})

        (def key (auth/get-api-key "anthropic"))
        (t/assert= "valid-token" key)

        # Verify no HTTP request was made (last-request should be empty)
        (def req (fake/get-last-request))
        (t/assert-truthy (empty? req))))))

# ── Runtime key takes priority over oauth ────────────────────

(t/test "runtime key takes priority over oauth credential"
  (fn []
    (with-clean-auth
      (fn []
        (auth/set-credential "anthropic"
          @{"type" "oauth"
            "access" "oauth-token"
            "refresh" "rt"
            "expires" 0})

        (auth/set-runtime-key "anthropic" "runtime-override-key")

        (def key (auth/get-api-key "anthropic"))
        (t/assert= "runtime-override-key" key)

        # No HTTP request should have been made for refresh
        (def req (fake/get-last-request))
        (t/assert-truthy (empty? req))))))

# ── Anthropic exchange-code ──────────────────────────────────

(t/test "Anthropic exchange-code sends correct request and parses response"
  (fn []
    (with-clean-auth
      (fn []
        (fake/queue-request-response
          (json/encode @{:access_token "exchanged-access"
                         :refresh_token "exchanged-refresh"
                         :expires_in 3600}))

        (def pkce {:verifier "test-verifier" :challenge "test-challenge"})
        (def cred (auth/anthropic-exchange-code "mycode#mystate" pkce))

        (t/assert= "oauth" (get cred "type"))
        (t/assert= "exchanged-access" (get cred "access"))
        (t/assert= "exchanged-refresh" (get cred "refresh"))
        (t/assert-truthy (get cred "expires"))

        (def req (fake/get-last-request))
        (t/assert= "POST" (req :method))
        (t/assert-truthy (string/find "oauth/token" (req :url)))))))

(t/test "Anthropic exchange-code throws on nil response"
  (fn []
    (with-clean-auth
      (fn []
        (def pkce {:verifier "v" :challenge "c"})
        (var caught nil)
        (try
          (auth/anthropic-exchange-code "code#state" pkce)
          ([err] (set caught err)))
        (t/assert-truthy caught)
        (t/assert-truthy (string/find "no response" (string caught)))))))

(t/test "Anthropic exchange-code throws on empty auth code"
  (fn []
    (with-clean-auth
      (fn []
        (def pkce {:verifier "v" :challenge "c"})
        (var caught nil)
        (try
          (auth/anthropic-exchange-code "" pkce)
          ([err] (set caught err)))
        (t/assert-truthy caught)
        (t/assert-truthy (string/find "No authorization code" (string caught)))))))

(def pass (t/pass))
(def fail (t/fail))
