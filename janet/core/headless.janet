# core/headless.janet — Headless JSON-RPC reactor for gent.
#
# An alternative to core/agent.janet that exposes the agent over TCP
# using JSON-RPC 2.0. No TUI, no terminal — just a socket server.
#
# Start with: gent --headless [--port 7888]

(import core/conversation :as conv)
(import core/rpc-server :as rpc-server)
(import core/observability :as obs)
(import widgets/chat :as chat)

# ── Main reactor loop ────────────────────────────────────────

(defn run [port]
  (def server (rpc-server/start port))
  (when (nil? server) (break))

  # Initialize conversation
  (def sid (conv/init))
  (obs/init sid)

  # Create chat widget (state machine) without TUI registration
  (chat/create)

  # Install event hooks
  (rpc-server/install-hooks server)

  (def metrics-port (obs/get-http-port))
  (eprintf "headless: listening on port %d (session %s)" port sid)
  (when metrics-port
    (eprintf "metrics: http://localhost:%d/metrics" metrics-port))

  (defer (do
          (rpc-server/stop server)
          (obs/stop))
    (while (not (rpc-server/shutdown-requested? server))
      # 1. Accept connections and process requests
      (rpc-server/poll-and-dispatch server)

      # 2. Tick the chat state machine
      (chat/tick)

      # 3. Poll observability HTTP server
      (obs/poll-http)

      # 4. Check for mode changes
      (rpc-server/check-mode-change server)

      # 5. Flush notifications to all clients
      (rpc-server/flush server)

      # 6. Sleep — shorter when active, longer when idle
      (def sleep-ms (if (chat/active?) 16 100))
      (os/sleep (/ sleep-ms 1000)))))
