# Slash commands — user-facing commands typed in the input line.
# Commands start with "/" and are intercepted before being sent to the API.
#
# Usage:
#   (import core/commands :as commands)
#   (commands/register "fork" {:description "Fork the conversation"
#                               :usage "/fork"
#                               :function (fn [args] ...)})
#   (commands/dispatch "/fork")  # => {:handled true :result "..."}

# ── Registry ──────────────────────────────────────────────────

(var- registry @{})

(defn register
  "Register a slash command.
   name: string (without the leading /)
   opts: {:description string :usage string :function (fn [args-string] result-string)}"
  [name opts]
  (put registry name opts)
  name)

(defn list-commands
  "Return a sorted array of [name description] tuples."
  []
  (sort-by first
    (seq [[k v] :pairs registry]
      [k (get v :description "")])))

(defn dispatch
  "Try to dispatch a string as a slash command.
   Returns {:handled true :result string} if it was a command,
   or {:handled false} if the input is not a slash command."
  [input]
  (unless (string/has-prefix? "/" input)
    (break {:handled false}))

  (def trimmed (string/slice input 1))  # strip leading /
  (def parts (string/split " " trimmed 2))  # split into [cmd args] at most 2 parts
  (def cmd-name (get parts 0 ""))
  (def args (get parts 1 ""))

  (when (= cmd-name "")
    (break {:handled false}))

  (def cmd (get registry cmd-name))
  (unless cmd
    (break {:handled true
            :result (string "Unknown command: /" cmd-name ". Type /help for available commands.")}))

  (def f (get cmd :function))
  (def result
    (try
      (f args)
      ([err]
        (string "Command error: " err))))
  {:handled true :result (or result "")})