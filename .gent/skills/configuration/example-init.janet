# Example gent configuration file
# Place this file at ~/.gent/init.janet to customize gent

# Auto-detect OS theme (dark/light mode)
(import widgets/chat :as chat)
(chat/auto-theme)

# Increase tool result display lines
(chat/set-tool-result-max-lines 15)

# Add a simple greeting hook
(import core/hooks :as hooks)
(hooks/add :after-response 
  (fn [response]
    (printf "Response received with %d content blocks" 
            (length (get response :content @[])))))

# Custom tool example
(import core/tools :as tools)
(tools/register "hello"
  {:description "Say hello with optional name"
   :schema {:type "object"
            :properties {:name {:type "string" :description "Name to greet"}}
            :required []}
   :function (fn [input]
               (def name (get input :name "World"))
               (string "Hello, " name "!"))})

# Custom slash command
(import core/commands :as commands)
(commands/register "time"
  {:description "Show current time"
   :usage "/time"
   :function (fn [args] 
               (def now (os/date))
               (string/format "Current time: %s" now))})

(print "Example gent configuration loaded!")