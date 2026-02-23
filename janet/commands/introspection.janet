(import core/commands :as commands)
(import core/tools :as tools)
(import core/hooks :as hooks)
(import core/skills :as skills)
(import core/api :as api)

(commands/register "tools"
  {:description "List registered tools"
   :usage "/tools"
   :function (fn [args]
     (def names (sort (tools/list-registered)))
     (if (empty? names)
       "No tools registered."
       (do
         (def lines @[(string (length names) " tools:")])
         (each name names
           (def tool (tools/get-tool name))
           (def desc (if tool (get tool :description "") ""))
           (array/push lines (string "  " name " — " desc)))
         (string/join lines "\n"))))})

(commands/register "hooks"
  {:description "List active hooks"
   :usage "/hooks"
   :function (fn [args]
     (def hook-names (sort (hooks/list-hooks)))
     (if (empty? hook-names)
       "No hooks registered."
       (do
         (def lines @[(string (length hook-names) " hooks:")])
         (each name hook-names
           (def fns (hooks/list-functions name))
           (array/push lines (string "  " name " (" (length fns) " fn)")))
         (string/join lines "\n"))))})

(commands/register "skills"
  {:description "List discovered skills"
   :usage "/skills"
   :function (fn [args]
     (def skill-list (skills/list-skills))
     (if (empty? skill-list)
       "No skills discovered."
       (do
         (def lines @[(string (length skill-list) " skills:")])
         (each s (sort-by |($ :name) skill-list)
           (array/push lines (string "  " (s :name) " — " (s :description))))
         (string/join lines "\n"))))})

(commands/register "config"
  {:description "Show API configuration"
   :usage "/config"
   :function (fn [args]
     (def cfg (api/get-config))
     (def lines @["API configuration:"
                  (string "  model: " (get cfg :model))
                  (string "  url: " (get cfg :url))
                  (string "  max-tokens: " (get cfg :max-tokens))
                  (string "  api-key: " (get cfg :api-key "not set"))
                  (string "  api-key-source: " (get cfg :api-key-source "none"))])
     (string/join lines "\n"))})
