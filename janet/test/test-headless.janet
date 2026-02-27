(import test/helper :as t)
(import test/fake-http :as fake)
(import core/rpc :as rpc)
(import core/conversation :as conv)
(import core/tools :as tools)
(import core/skills :as skills)
(import core/hooks :as hooks)
(import widgets/chat :as chat)
(import core/stage :as stage)

# ── Helpers ──────────────────────────────────────────────────

(defn- make-request [method &opt params id]
  (default id 1)
  (def req @{:jsonrpc "2.0" :method method :id id})
  (when params (put req :params params))
  (json/encode req))

(defn- decode-response [json-str]
  (json/decode json-str))

(defn- find-response-by-id
  "Find a response with a given id from an array of JSON strings.
   Skips notifications (no id field)."
  [writes target-id]
  (var result nil)
  (each w writes
    (def decoded (json/decode w))
    (when (= target-id (get decoded :id))
      (set result decoded)
      (break)))
  result)

# ── Import headless (after mocks are installed) ──────────────

(import core/headless :as headless)

# ── Unit tests (no headless/run) ─────────────────────────────

(t/test "agent.status returns mode and session info" (fn []
                                                      (chat/reset-state)
                                                      (conv/init)
                                                      (def listener-id (net/listen 0))
                                                      (def conn-id (fake/net-inject-connection listener-id
                                                                    [(make-request "agent.status")]))
                                                      (def parsed (rpc/parse-request (make-request "agent.status")))
                                                      (t/assert-truthy (get parsed :method))
                                                      (t/assert= "agent.status" (get parsed :method))
                                                      (fake/net-reset)))

(t/test "chat.submit parses correctly" (fn []
                                        (def req (make-request "chat.submit" @{:text "hello"}))
                                        (def parsed (rpc/parse-request req))
                                        (t/assert= "chat.submit" (get parsed :method))
                                        (t/assert= "hello" (get-in parsed [:params :text]))
                                        (fake/net-reset)))

(t/test "shutdown parses correctly" (fn []
                                     (def req (make-request "shutdown"))
                                     (def parsed (rpc/parse-request req))
                                     (t/assert= "shutdown" (get parsed :method))
                                     (fake/net-reset)))

(t/test "conversation.rollback with params" (fn []
                                             (def req (make-request "conversation.rollback" @{:n 3}))
                                             (def parsed (rpc/parse-request req))
                                             (t/assert= "conversation.rollback" (get parsed :method))
                                             (t/assert= 3 (get-in parsed [:params :n]))
                                             (fake/net-reset)))

(t/test "tools.list returns tool names" (fn []
                                         (def tool-names (tools/list-registered))
                                         (t/assert-truthy (>= (length tool-names) 0))
                                         (fake/net-reset)))

(t/test "skills.list returns skill info" (fn []
                                          (def skill-list (skills/list-skills))
                                          (t/assert-truthy (>= (length skill-list) 0))
                                          (fake/net-reset)))

(t/test "notification format is valid JSON-RPC" (fn []
                                                 (def note (rpc/format-notification "agent.done" @{}))
                                                 (def decoded (json/decode note))
                                                 (t/assert= "2.0" (get decoded :jsonrpc))
                                                 (t/assert= "agent.done" (get decoded :method))
                                                 (t/assert-truthy (not (has-key? decoded :id)))))

(t/test "error response for unknown method" (fn []
                                             (def req (make-request "unknown.method"))
                                             (def parsed (rpc/parse-request req))
                                             (t/assert= "unknown.method" (get parsed :method))))

(t/test "net mock: listen and accept" (fn []
                                       (fake/net-reset)
                                       (def lid (net/listen 9999))
                                       (t/assert-truthy lid)
                                       (def conn-id (fake/net-inject-connection lid))
                                       (def accepted (net/accept lid 0))
                                       (t/assert= conn-id accepted)
                                       (fake/net-reset)))

(t/test "net mock: write and read-back" (fn []
                                         (fake/net-reset)
                                         (def lid (net/listen 9999))
                                         (def conn-id (fake/net-inject-connection lid @["hello" "world"]))
                                         (def accepted (net/accept lid 0))
                                         (t/assert= "hello" (net/read-line accepted))
                                         (t/assert= "world" (net/read-line accepted))
                                         (t/assert= nil (net/read-line accepted))
                                         (t/assert-truthy (net/write accepted "response"))
                                         (def writes (fake/net-get-writes accepted))
                                         (t/assert= 1 (length writes))
                                         (t/assert= "response" (first writes))
                                         (fake/net-reset)))

(t/test "net mock: close returns closed" (fn []
                                          (fake/net-reset)
                                          (def lid (net/listen 9999))
                                          (def conn-id (fake/net-inject-connection lid))
                                          (def accepted (net/accept lid 0))
                                          (net/close accepted)
                                          (t/assert= :closed (net/read-line accepted))
                                          (fake/net-reset)))

(t/test "net mock: accept with no pending returns nil" (fn []
                                                        (fake/net-reset)
                                                        (def lid (net/listen 9999))
                                                        (t/assert= nil (net/accept lid 0))
                                                        (fake/net-reset)))

(t/test "headless module loads without error" (fn []
                                               (t/assert-truthy headless/run)))

# ── Integration tests (using headless/run) ────────────────────
# headless/run calls net/listen (gets listener-id 1 after reset),
# conv/init (fresh session), chat/create, install-hooks, then loops.
# It pushes a "client connected" notification on accept, so writes
# may include notifications interleaved with responses. Use
# find-response-by-id to locate the response we care about.

(t/test "headless run: agent.status then shutdown" (fn []
                                                    (fake/net-reset)
                                                    (chat/reset-state)
  # Inject connection for listener-id 1 (what headless/run will get)
                                                    (def conn-id (fake/net-inject-connection 1
                                                                  [(make-request "agent.status" nil 10)
                                                                   (make-request "shutdown" nil 11)]))
                                                    (headless/run 0)
                                                    (def writes (fake/net-get-writes conn-id))
                                                    (t/assert-truthy (>= (length writes) 2))
                                                    (def resp (find-response-by-id writes 10))
                                                    (t/assert-truthy resp)
                                                    (t/assert= "idle" (get-in resp [:result :mode]))
                                                    (t/assert-truthy (get-in resp [:result :session_id]))
                                                    (t/assert-truthy (>= (get-in resp [:result :message_count]) 0))
                                                    (fake/net-reset)))

(t/test "headless run: tools.list returns array" (fn []
                                                  (fake/net-reset)
                                                  (chat/reset-state)
                                                  (def conn-id (fake/net-inject-connection 1
                                                                [(make-request "tools.list" nil 20)
                                                                 (make-request "shutdown" nil 21)]))
                                                  (headless/run 0)
                                                  (def writes (fake/net-get-writes conn-id))
                                                  (def resp (find-response-by-id writes 20))
                                                  (t/assert-truthy resp)
                                                  (t/assert-truthy (get-in resp [:result :tools]))
                                                  (t/assert-truthy (or (array? (get-in resp [:result :tools]))
                                                                       (tuple? (get-in resp [:result :tools]))))
                                                  (fake/net-reset)))

(t/test "headless run: unknown method returns error" (fn []
                                                      (fake/net-reset)
                                                      (chat/reset-state)
                                                      (def conn-id (fake/net-inject-connection 1
                                                                    [(make-request "nonexistent.method" nil 30)
                                                                     (make-request "shutdown" nil 31)]))
                                                      (headless/run 0)
                                                      (def writes (fake/net-get-writes conn-id))
                                                      (def resp (find-response-by-id writes 30))
                                                      (t/assert-truthy resp)
                                                      (t/assert-truthy (get resp :error))
                                                      (t/assert= rpc/method-not-found (get-in resp [:error :code]))
                                                      (fake/net-reset)))

(t/test "headless run: conversation.clear works" (fn []
                                                  (fake/net-reset)
                                                  (chat/reset-state)
                                                  (def conn-id (fake/net-inject-connection 1
                                                                [(make-request "conversation.clear" nil 40)
                                                                 (make-request "shutdown" nil 41)]))
                                                  (headless/run 0)
                                                  (def writes (fake/net-get-writes conn-id))
                                                  (def resp (find-response-by-id writes 40))
                                                  (t/assert-truthy resp)
                                                  (t/assert= "ok" (get-in resp [:result :status]))
                                                  (t/assert= 0 (conv/length))
                                                  (fake/net-reset)))

(t/test "headless run: invalid JSON returns parse error" (fn []
                                                          (fake/net-reset)
                                                          (chat/reset-state)
                                                          (def conn-id (fake/net-inject-connection 1
                                                                        ["not valid json"
                                                                         (make-request "shutdown" nil 50)]))
                                                          (headless/run 0)
                                                          (def writes (fake/net-get-writes conn-id))
  # Find the error response (it has no id since parsing failed)
                                                          (var parse-err nil)
                                                          (each w writes
                                                            (def decoded (json/decode w))
                                                            (when (get decoded :error)
                                                              (set parse-err decoded)
                                                              (break)))
                                                          (t/assert-truthy parse-err)
                                                          (t/assert= rpc/parse-error (get-in parse-err [:error :code]))
                                                          (fake/net-reset)))

(t/test "headless run: connection close is handled" (fn []
                                                     (fake/net-reset)
                                                     (chat/reset-state)
  # First connection closes immediately
                                                     (fake/net-inject-connection 1 @[:closed])
  # Second connection with shutdown
                                                     (def conn2 (fake/net-inject-connection 1
                                                                 [(make-request "shutdown" nil 60)]))
                                                     (headless/run 0)
                                                     (def writes (fake/net-get-writes conn2))
                                                     (def resp (find-response-by-id writes 60))
                                                     (t/assert-truthy resp)
                                                     (t/assert= "ok" (get-in resp [:result :status]))
                                                     (fake/net-reset)))

(t/test "headless run: conversation.get returns empty after init" (fn []
                                                                   (fake/net-reset)
                                                                   (chat/reset-state)
                                                                   (def conn-id (fake/net-inject-connection 1
                                                                                 [(make-request "conversation.get" nil 70)
                                                                                  (make-request "shutdown" nil 71)]))
                                                                   (headless/run 0)
                                                                   (def writes (fake/net-get-writes conn-id))
                                                                   (def resp (find-response-by-id writes 70))
                                                                   (t/assert-truthy resp)
                                                                   (def msgs (get-in resp [:result :messages]))
                                                                   (t/assert-truthy msgs)
                                                                   (t/assert= 0 (length msgs))
                                                                   (fake/net-reset)))

(t/test "headless run: skills.list returns array" (fn []
                                                   (fake/net-reset)
                                                   (chat/reset-state)
                                                   (def conn-id (fake/net-inject-connection 1
                                                                 [(make-request "skills.list" nil 80)
                                                                  (make-request "shutdown" nil 81)]))
                                                   (headless/run 0)
                                                   (def writes (fake/net-get-writes conn-id))
                                                   (def resp (find-response-by-id writes 80))
                                                   (t/assert-truthy resp)
                                                   (t/assert-truthy (get-in resp [:result :skills]))
                                                   (fake/net-reset)))

(t/test "headless run: conversation.sessions returns array" (fn []
                                                             (fake/net-reset)
                                                             (chat/reset-state)
                                                             (def conn-id (fake/net-inject-connection 1
                                                                           [(make-request "conversation.sessions" nil 90)
                                                                            (make-request "shutdown" nil 91)]))
                                                             (headless/run 0)
                                                             (def writes (fake/net-get-writes conn-id))
                                                             (def resp (find-response-by-id writes 90))
                                                             (t/assert-truthy resp)
                                                             (t/assert-truthy (get-in resp [:result :sessions]))
                                                             (fake/net-reset)))

(t/test "headless run: multiple requests in sequence" (fn []
                                                       (fake/net-reset)
                                                       (chat/reset-state)
                                                       (def conn-id (fake/net-inject-connection 1
                                                                     [(make-request "agent.status" nil 100)
                                                                      (make-request "tools.list" nil 101)
                                                                      (make-request "skills.list" nil 102)
                                                                      (make-request "shutdown" nil 103)]))
                                                       (headless/run 0)
                                                       (def writes (fake/net-get-writes conn-id))
                                                       (def status (find-response-by-id writes 100))
                                                       (def tools-resp (find-response-by-id writes 101))
                                                       (def skills-resp (find-response-by-id writes 102))
                                                       (def shutdown-resp (find-response-by-id writes 103))
                                                       (t/assert-truthy status)
                                                       (t/assert-truthy tools-resp)
                                                       (t/assert-truthy skills-resp)
                                                       (t/assert-truthy shutdown-resp)
                                                       (t/assert= "idle" (get-in status [:result :mode]))
                                                       (t/assert-truthy (get-in tools-resp [:result :tools]))
                                                       (t/assert-truthy (get-in skills-resp [:result :skills]))
                                                       (t/assert= "ok" (get-in shutdown-resp [:result :status]))
                                                       (fake/net-reset)))
