# Built-in slash commands for conversation management.
# Imported at boot to register /sessions, /resume, /fork, etc.

(import core/commands :as commands)
(import core/conversation :as conv)

(commands/register "help"
  {:description "Show available commands"
   :usage "/help"
   :function (fn [args]
              (def cmds (commands/list-commands))
              (def lines @["Available commands:"])
              (each [name desc] cmds
                (array/push lines (string "  /" name " — " desc)))
              (string/join lines "\n"))})

(commands/register "session"
  {:description "Show current session ID and path"
   :usage "/session"
   :function (fn [args]
              (string "Session: " (conv/get-session-id) "\n"
                      "Path: " (conv/get-session-path) "\n"
                      "Messages: " (conv/length) "\n"
                      "Tokens (est): ~" (conv/estimate-tokens)))})

(commands/register "sessions"
  {:description "List all sessions for this project"
   :usage "/sessions"
   :function (fn [args]
              (def sessions (conv/list-sessions))
              (if (empty? sessions)
                "No sessions found."
                (do
                  (def current (conv/get-session-id))
                  (def lines @["Sessions (chronological order):"])
                  (each s sessions
                    (def marker (if (= s current) " (current)" ""))
                    # Parse timestamp from session ID for better display
                    (if (string/has-prefix? s "20")
                      (do
                        (def parts (string/split "-" s))
                        (when (>= (length parts) 3)
                          (def date-part (get parts 0))
                          (def time-part (get parts 1))
                          (def counter-part (get parts 2))
                          (def date-str (string (string/slice date-part 0 4) "/"
                                               (string/slice date-part 4 6) "/"
                                               (string/slice date-part 6 8)))
                          (def time-str (string (string/slice time-part 0 2) ":"
                                               (string/slice time-part 2 4) ":"
                                               (string/slice time-part 4 6)))
                          (array/push lines (string "  " s " — " date-str " " time-str marker))))
                      # Fallback for old random session IDs
                      (array/push lines (string "  " s marker))))
                  (string/join lines "\n"))))})

(commands/register "resume"
  {:description "Resume a previous session"
   :usage "/resume <session-id>"
   :function (fn [args]
              (def sid (string/trim args))
              (when (= "" sid)
                (break "Usage: /resume <session-id>"))
              (conv/resume sid)
              (string "Resumed session " sid " (" (conv/length) " messages)"))})

(commands/register "fork"
  {:description "Fork the conversation into a new session"
   :usage "/fork"
   :function (fn [args]
              (def new-sid (conv/fork))
              (string "Forked → " new-sid " (" (conv/length) " messages)"))})

(commands/register "unfork"
  {:description "Return to the parent session (before the last fork)"
   :usage "/unfork"
   :function (fn [args]
              (def pid (conv/unfork))
              (if pid
                (string "Returned to session " pid " (" (conv/length) " messages)")
                "No parent session to return to."))})

(commands/register "rollback"
  {:description "Remove the last n messages (default: 2)"
   :usage "/rollback [n]"
   :function (fn [args]
              (def n-str (string/trim args))
              (def n (if (= "" n-str) 2 (scan-number n-str)))
              (unless n
                (break "Usage: /rollback [n] — n must be a number"))
              (conv/rollback n)
              (string "Rolled back " n " messages (" (conv/length) " remaining)"))})

(commands/register "clear"
  {:description "Clear the conversation (fresh start, same session)"
   :usage "/clear"
   :function (fn [args]
              (conv/clear)
              "Conversation cleared.")})

(commands/register "tokens"
  {:description "Estimate token usage for the current conversation"
   :usage "/tokens"
   :function (fn [args]
              (string "Messages: " (conv/length) "\n"
                      "Estimated tokens: ~" (conv/estimate-tokens)))})

(commands/register "eval"
  {:description "Evaluate Janet code inline"
   :usage "/eval (+ 1 2)"
   :function (fn [args]
              (def code (string/trim args))
              (when (= "" code)
                (break "Usage: /eval <janet-code>\nTip: use ,<code> as a shortcut"))
              (try
                (do
                  (def result (eval-string code))
                  (if (or (string? result) (number? result) (boolean? result) (nil? result))
                    (string "=> " result)
                    (string "=> " (string/format "%q" result))))
                ([err]
                 (string "Error: " err))))})

(commands/register "quit"
  {:description "Quit gent"
   :usage "/quit"
   :function (fn [args] :quit)})
