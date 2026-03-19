# commands/usage.janet — /usage slash command.
# Shows token usage, cost, and tool stats for the current session.

(import core/commands :as commands)
(import core/observability :as obs)

(commands/register "usage"
  {:description "Show token usage, cost, and tool stats for this session"
   :usage "/usage"
   :function (fn [_] (obs/format-usage))})
