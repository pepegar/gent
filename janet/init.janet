# User configuration — like .emacs
# Override anything here. This file is loaded after core modules and tools.
#
# Examples:
#
# Point at a LiteLLM proxy:
# (import core/api :as api)
# (api/set-url "http://localhost:4000/v1/messages")
# (api/set-model "anthropic/claude-sonnet-4-20250514")
#
# Or just tweak defaults:
# (api/set-max-tokens 16384)
#
# Change the system prompt:
# (import core/agent :as agent)
# (agent/set-system-prompt "You are a Haskell expert...")
#
# Define a custom tool:
# (import core/tools :as tools)
# (tools/register "my_tool"
#   {:description "Does something cool"
#    :schema {:type "object" :properties {:x {:type "string"}} :required ["x"]}
#    :function (fn [input] (string "got: " (get input "x")))})
#
# Add hooks:
# (import core/hooks :as hooks)
# (hooks/add :before-tool-call (fn [name input] (print "calling tool:" name)))
# (hooks/add :after-tool-call (fn [name input result] (printf "tool %s done" name)))
# (hooks/add :before-send (fn [conv] (printf "sending %d messages" (length conv))))
# (hooks/add :on-error (fn [err] (printf "error: %s" (string err))))
#
# Add extra skill search paths:
# (import core/skills :as skills)
# (skills/add-path "/path/to/shared/skills")
# (skills/discover)  # re-discover after adding paths
