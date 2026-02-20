# The agent loop — the brain of the machine.
# This is the equivalent of Emacs's command loop.
# Everything here is Janet and can be redefined at runtime.

(import core/tools :as tools)
(import core/api :as api)
(import core/ui :as ui)
(import core/editor :as editor)
(import core/skills :as skills)
(import core/agents-md :as agents-md)

(var- system-prompt
  `````
  You are gent, an extensible coding agent built as a lisp machine in Janet (a Lisp).
  You help users by reading files, editing code, running commands, and writing new files.
  Be concise and direct. When you need information, use your tools.

  ## Creating tools at runtime with eval_janet

  You can define new tools by evaluating Janet code. Here is a working example:

  ```janet
  (import core/tools :as tools)

  (tools/register "grep"
    {:description "Search for a pattern in files using grep"
     :schema {:type "object"
              :properties {:pattern {:type "string" :description "Pattern to search for"}
                           :path {:type "string" :description "Directory to search in"}}
              :required ["pattern"]}
     :function (fn [input]
                 (def result (process/exec "grep" ["-rn" (get input :pattern) (or (get input :path) ".")]))
                 (if (= 0 (get result :status))
                   (get result :stdout)
                   (string "No matches. stderr: " (get result :stderr))))})
  ```

  ## Janet cheat sheet

  - Strings: `"hello"` Keywords: `:keyword` Comments: `#`
  - Variables: `(def x 10)` Mutable: `(var x 10)` `(set x 20)`
  - Functions: `(defn name [args] body)` Anonymous: `(fn [args] body)`
  - Tables (mutable dict): `@{:key "val"}` Structs (immutable): `{:key "val"}`
  - Arrays (mutable): `@[1 2 3]` Tuples (immutable): `[1 2 3]`
  - Conditionals: `(if cond then else)` `(when cond body)` `(unless cond body)`
  - Loops: `(each x arr body)` `(while cond body)` — while always returns nil
  - String ops: `(string "a" "b")` `(string/find "pat" s)` `(string/split "\n" s)`
  - File I/O: `(slurp "path")` `(spit "path" "content")` `(os/dir ".")` `(os/stat "path")`
  - Process: `(process/exec "cmd" ["arg1" "arg2"])` returns `{:stdout :stderr :status}`
  - Error handling: `(try body ([err] handler))`
  - Table access: `(get tbl :key)` `(get tbl :key default)` `(put tbl :key val)`
  - IMPORTANT: `(while)` always returns nil. Use `(var result nil)` before the loop.
  - IMPORTANT: Use `(import core/tools :as tools)` then `(tools/register name definition)`.
  `````)

(defn set-system-prompt
  "Override the system prompt. Call from init.janet to customize."
  [prompt]
  (set system-prompt prompt))

(defn- handle-tool-calls
  "Execute tool calls from the assistant response. Returns [assistant-msg tool-results] or nil."
  [response]
  (def content (get response :content []))
  (def tool-calls (filter |(= "tool_use" ($ :type)) content))

  (when (empty? tool-calls)
    (break nil))

  # Build the assistant message to add to conversation
  (def assistant-msg {:role "assistant" :content content})

  # Execute each tool call
  (def tool-results
    (seq [tc :in tool-calls]
      (if (= "eval_janet" (tc :name))
        (ui/output-eval-janet (get (tc :input) :code ""))
        (ui/output-tool (tc :name) (json/encode (tc :input))))
      (def result (tools/dispatch (tc :name) (tc :input)))
      (ui/output-tool-result (string result))
      {:type "tool_result"
       :tool_use_id (tc :id)
       :content (string result)}))

  [assistant-msg {:role "user" :content tool-results}])

(defn- print-text-response [response]
  (def content (get response :content []))
  (each block content
    (when (= "text" (block :type))
      (ui/output-agent (block :text)))))

(defn run
  "Main agent loop. Reads input, sends to Claude, executes tools, loops."
  []
  # Set up TUI
  (ui/setup)
  (defer (ui/teardown)

    (ui/output-info "gent — the extensible coding agent")
    (ui/output-info (string "  " (length (tools/list-registered)) " tools loaded — ctrl-c to quit"))
    (def skill-list (skills/list-skills))
    (when (not (empty? skill-list))
      (ui/output-info (string "  " (length skill-list) " skills:"))
      (each s (sort-by |($ :name) skill-list)
        (ui/output-info (string "    • " (s :name) " — " (s :path)))))
    (def agents-md-files (agents-md/list-files))
    (when (not (empty? agents-md-files))
      (ui/output-info (string "  " (length agents-md-files) " AGENTS.md:"))
      (each path agents-md-files
        (ui/output-info (string "    • " path))))

    (var conversation @[])

    (while true
      # Read user input via the editor
      (def input (editor/read-input))
      (unless input (break))

      # Skip empty input
      (when (not= "" input)
        # Show the user message in the output area
        (ui/output-user input)

        # Add user message to conversation
        (array/push conversation {:role "user" :content input})

        # Agent loop: keep going until no more tool calls
        (var looping true)
        (while looping
          # Build effective system prompt (base + AGENTS.md + skills)
          (def agents-md-snippet (agents-md/system-prompt-snippet))
          (def skills-snippet (skills/system-prompt-snippet))
          (def effective-prompt
            (string system-prompt
                    (if (not= "" agents-md-snippet) (string "\n" agents-md-snippet) "")
                    (if (not= "" skills-snippet) (string "\n" skills-snippet) "")))

          # Call the API (with error handling)
          (var response nil)
          (try
            (set response (api/chat conversation (tools/definitions) effective-prompt))
            ([err]
              (ui/output-error (string err))
              (set looping false)
              (break)))

          # Check for nil response
          (when (nil? response)
            (ui/output-error "API request failed — nil response")
            (set looping false)
            (break))

          # Handle tool calls if any
          (def tool-result (handle-tool-calls response))

          (if tool-result
            (do
              # Add assistant message and tool results to conversation
              (array/push conversation (tool-result 0))
              (array/push conversation (tool-result 1)))
            (do
              # No tool calls — print text response and wait for next input
              (print-text-response response)
              (array/push conversation {:role "assistant" :content (get response :content [])})
              (set looping false))))))))
