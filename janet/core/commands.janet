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
   or {:handled false} if the input is not a slash command.
   Supports colon syntax for compound commands (e.g. /skill:pdf → command 'skill' with args 'pdf')."
  [input]
  (unless (string/has-prefix? "/" input)
    (break {:handled false}))

  (def trimmed (string/slice input 1))  # strip leading /
  (def parts (string/split " " trimmed 2))  # split into [cmd args] at most 2 parts
  (def cmd-name (get parts 0 ""))
  (def args (get parts 1 ""))

  (when (= cmd-name "")
    (break {:handled false}))

  # Try exact match first
  (var cmd (get registry cmd-name))
  (var effective-args args)

  # If no exact match, try colon syntax: "skill:pdf" → command "skill", args "pdf"
  (when (nil? cmd)
    (def colon-idx (string/find ":" cmd-name))
    (when colon-idx
      (def base (string/slice cmd-name 0 colon-idx))
      (def colon-arg (string/slice cmd-name (+ colon-idx 1)))
      (def base-cmd (get registry base))
      (when base-cmd
        (set cmd base-cmd)
        (set effective-args (if (= args "") colon-arg (string colon-arg " " args))))))

  (unless cmd
    (break {:handled true
            :result (string "Unknown command: /" cmd-name ". Type /help for available commands.")}))

  (def f (get cmd :function))
  (def result
    (try
      (f effective-args)
      ([err]
       (string "Command error: " err))))
  {:handled true :result (or result "")})
