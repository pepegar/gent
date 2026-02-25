# core/rpc-server.janet — Shared JSON-RPC server for gent.
#
# Extracted from headless.janet so both the TUI reactor and headless
# reactor can embed an RPC server. Manages TCP connections, parses
# JSON-RPC requests, dispatches methods, and broadcasts notifications.
#
# Usage:
#   (def server (rpc-server/start 7888))
#   # in your loop:
#   (rpc-server/poll-and-dispatch server)
#   (rpc-server/check-mode-change server)
#   (rpc-server/flush server)
#   # cleanup:
#   (rpc-server/stop server)

(import core/tools :as tools)
(import core/conversation :as conv)
(import core/commands :as commands)
(import core/hooks :as hooks)
(import core/skills :as skills)
(import core/rpc :as rpc)
(import widgets/chat :as chat)

# ── Server creation ──────────────────────────────────────────

(defn start
  "Start an RPC server on the given port. Returns a server table."
  [port]
  (def listener-id (net/listen port))
  (when (nil? listener-id)
    (eprintf "rpc-server: failed to listen on port %d" port)
    (break nil))
  (def server
    @{:listener-id listener-id
      :port port
      :connections @{}
      :notification-queue @[]
      :last-mode :idle
      :shutdown-requested false})
  (eprintf "rpc-server: listening on port %d" port)
  server)

# ── Connection management ────────────────────────────────────

(defn- active-connections [server]
  (seq [[id alive] :pairs (server :connections) :when alive] id))

(defn- add-connection [server conn-id]
  (put (server :connections) conn-id true))

(defn- remove-connection [server conn-id]
  (put (server :connections) conn-id nil)
  (net/close conn-id))

# ── Notification queue ───────────────────────────────────────

(defn push-notification
  "Queue a JSON-RPC notification to be sent to all clients."
  [server method params]
  (array/push (server :notification-queue) (rpc/format-notification method params)))

(defn flush
  "Send all queued notifications to connected clients."
  [server]
  (def conns (active-connections server))
  (each note (server :notification-queue)
    (each conn-id conns
      (when (not (net/write conn-id note))
        (remove-connection server conn-id))))
  (array/clear (server :notification-queue)))

# ── Hook integration ─────────────────────────────────────────

(defn install-hooks
  "Set up hooks that push notifications for agent events."
  [server]
  (hooks/add :after-message
    (fn [msg]
      (push-notification server "agent.output"
        @{:type (get msg :role "unknown")
          :content (get msg :content "")})))

  (hooks/add :before-tool-call
    (fn [name input]
      (push-notification server "agent.output"
        @{:type "tool_call"
          :content (string name)
          :input input})))

  (hooks/add :after-tool-call
    (fn [name input result]
      (push-notification server "agent.output"
        @{:type "tool_result"
          :content (string name)
          :result (if (string? result) result (string result))}))))

# ── Mode tracking ────────────────────────────────────────────

(defn check-mode-change
  "Check if chat mode changed and push notification if so."
  [server]
  (def current (chat/get-mode))
  (when (not= current (server :last-mode))
    (push-notification server "agent.mode_changed"
      @{:mode (string current) :previous (string (server :last-mode))})
    (when (= current :idle)
      (push-notification server "agent.done" @{}))
    (put server :last-mode current)))

# ── Method dispatch ──────────────────────────────────────────

(defn dispatch-method
  "Dispatch a JSON-RPC method. Returns @{:result ...} or @{:error ...}."
  [server method params]
  (case method
    "chat.submit"
    (do
      (def text (get params :text))
      (when (nil? text)
        (break @{:error @{:code rpc/invalid-params :message "Missing 'text' param"}}))
      (chat/submit text)
      @{:result @{:status "ok"}})

    "chat.stop"
    (do (chat/stop)
      @{:result @{:status "ok"}})

    "conversation.clear"
    (do (conv/clear)
      @{:result @{:status "ok"}})

    "conversation.rollback"
    (do
      (def n (get params :n 1))
      (conv/rollback n)
      @{:result @{:status "ok"}})

    "command.execute"
    (do
      (def cmd (get params :command))
      (when (nil? cmd)
        (break @{:error @{:code rpc/invalid-params :message "Missing 'command' param"}}))
      (def cmd-result (commands/dispatch cmd))
      @{:result @{:handled (get cmd-result :handled false)
                  :result (or (get cmd-result :result) "")}})

    "agent.status"
    @{:result @{:mode (string (chat/get-mode))
                :session_id (conv/get-session-id)
                :message_count (conv/length)
                :tokens (conv/estimate-tokens)}}

    "conversation.get"
    @{:result @{:messages (conv/get-messages)}}

    "conversation.sessions"
    @{:result @{:sessions (conv/list-sessions)}}

    "tools.list"
    (do
      (def tool-names (tools/list-registered))
      (def tool-list (seq [name :in tool-names]
                       @{:name (string name)}))
      @{:result @{:tools tool-list}})

    "skills.list"
    @{:result @{:skills (skills/list-skills)}}

    "shutdown"
    (do (put server :shutdown-requested true)
      @{:result @{:status "ok"}})

    @{:error @{:code rpc/method-not-found :message (string "Method not found: " method)}}))

# ── Request handling ─────────────────────────────────────────

(defn- handle-request [server conn-id line]
  (def parsed (rpc/parse-request line))
  (when (get parsed :error)
    (def err (get parsed :error))
    (def resp (rpc/format-error nil (get err :code) (get err :message)))
    (net/write conn-id resp)
    (break))
  (def method (get parsed :method))
  (def params (or (get parsed :params) @{}))
  (def id (get parsed :id))
  (def result
    (try
      (dispatch-method server method params)
      ([err]
        @{:error @{:code rpc/internal-error :message (string err)}})))
  (when (not (rpc/notification? parsed))
    (def resp
      (if (get result :error)
        (let [err (get result :error)]
          (rpc/format-error id (get err :code) (get err :message)))
        (rpc/format-response id (get result :result))))
    (when (not (net/write conn-id resp))
      (remove-connection server conn-id))))

# ── Poll loop step ───────────────────────────────────────────

(defn poll-and-dispatch
  "Accept new connections and process pending requests. Call once per frame."
  [server]
  # Accept new connections (non-blocking)
  (def new-conn (net/accept (server :listener-id) 0))
  (when new-conn
    (add-connection server new-conn)
    (push-notification server "agent.output"
      @{:type "info" :content "client connected"}))

  # Read from each connection
  (each conn-id (active-connections server)
    (def line (net/read-line conn-id))
    (cond
      (string? line)
      (handle-request server conn-id line)

      (= :closed line)
      (remove-connection server conn-id))))

(defn has-clients?
  "Return true if any clients are connected."
  [server]
  (> (length (active-connections server)) 0))

(defn shutdown-requested?
  "Return true if a shutdown RPC was received."
  [server]
  (server :shutdown-requested))

# ── Cleanup ──────────────────────────────────────────────────

(defn stop
  "Close all connections and the listener."
  [server]
  (each conn-id (active-connections server)
    (remove-connection server conn-id))
  (net/close-listener (server :listener-id)))
