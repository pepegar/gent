# core/headless.janet — Headless JSON-RPC reactor for gent.
#
# An alternative to core/agent.janet that exposes the agent over TCP
# using JSON-RPC 2.0. No TUI, no terminal — just a socket server.
#
# Start with: gent --headless [--port 7888]

(import core/conversation :as conv)
(import core/rpc-server :as rpc-server)
(import widgets/chat :as chat)

# ── Main reactor loop ────────────────────────────────────────

(defn run [port]
  (def server (rpc-server/start port))
  (when (nil? server) (break))

  # Initialize conversation
  (def sid (conv/init))

  # Create chat widget (state machine) without TUI registration
  (chat/create)

  # Install event hooks
  (rpc-server/install-hooks server)

  (eprintf "headless: listening on port %d (session %s)" port sid)

  (defer (rpc-server/stop server)
    (while (not (rpc-server/shutdown-requested? server))
      # 1. Accept connections and process requests
      (rpc-server/poll-and-dispatch server)

      # 2. Tick the chat state machine
      (chat/tick)

      # 3. Check for mode changes
      (rpc-server/check-mode-change server)

      # 4. Flush notifications to all clients
      (rpc-server/flush server)

      # 5. Sleep — shorter when active, longer when idle
      (def sleep-ms (if (chat/active?) 16 100))
      (os/sleep (/ sleep-ms 1000)))))
