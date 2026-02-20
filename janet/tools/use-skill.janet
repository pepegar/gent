(import core/tools :as tools)
(import core/skills :as skills)

(tools/register "use_skill"
  {:description ```Activate a skill to get specialized instructions for a task.
Skills provide detailed, step-by-step guidance for specific domains (e.g., PDF processing, git workflows).
Use this when the current task matches a skill's description listed in your system prompt.
The skill may reference files (scripts/, references/, assets/) relative to its directory — use read_file with the full path to access them.```
   :schema {:type "object"
            :properties {:name {:type "string"
                                :description "The name of the skill to activate"}}
            :required ["name"]}
   :function (fn [input]
               (def name (get input :name))
               (def result (skills/load-skill name))
               (if result
                 (string "# Skill: " (result :name) "\n"
                         "# Directory: " (result :path) "\n"
                         "# (Resolve any file references relative to the directory above)\n"
                         "\n"
                         (result :body))
                 (let [available (skills/list-skills)]
                   (if (empty? available)
                     (string "No skills are installed. "
                             "Place skill directories in .gent/skills/ or ~/.gent/skills/")
                     (string "Skill not found: " name "\n"
                             "Available skills: "
                             (string/join (map |($ :name) available) ", "))))))})
