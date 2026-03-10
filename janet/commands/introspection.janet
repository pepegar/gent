(import core/commands :as commands)
(import core/tools :as tools)
(import core/hooks :as hooks)
(import core/skills :as skills)
(import core/api :as api)
(import core/conversation :as conv)
(import widgets/chat :as chat)

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
                   (chat/output-skills skill-list)
                   "")))})

(commands/register "skill"
  {:description "Activate a skill (e.g. /skill:pdf)"
   :usage "/skill:<name>"
   :function (fn [args]
              (def name (string/trim args))
              (when (= name "")
                (break "Usage: /skill:<name> — activate a skill by name.\nUse /skills to list available skills."))
              (def result (skills/load-skill name))
              (if result
                (do
                  (conv/inject-context
                    (string "# Skill: " (result :name) "\n"
                            "# Directory: " (result :path) "\n"
                            "# (Resolve any file references relative to the directory above)\n"
                            "\n"
                            (result :body)))
                  (string "Activated skill: " (result :name)))
                (let [available (skills/list-skills)]
                  (if (empty? available)
                    "No skills installed. Place skill directories in .gent/skills/ or ~/.gent/skills/"
                    (string "Skill not found: " name "\n"
                            "Available: " (string/join (map |($ :name) available) ", "))))))})

(commands/register "config"
  {:description "Show API configuration"
   :usage "/config"
   :function (fn [args]
              (def cfg (api/get-config))
              (def lines @["API configuration:"
                           (string "  provider: " (get cfg :provider "unknown"))
                           (string "  model: " (get cfg :model))
                           (string "  url: " (get cfg :url))
                           (string "  max-tokens: " (get cfg :max-tokens))
                           (string "  api-key: " (get cfg :api-key "not set"))
                           (string "  api-key-source: " (get cfg :api-key-source "none"))])
              (string/join lines "\n"))})
