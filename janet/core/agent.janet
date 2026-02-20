# The agent loop — the brain of the machine.
# This is the equivalent of Emacs's command loop.
# Everything here is Janet and can be redefined at runtime.

(import core/tools :as tools)
(import core/api :as api)
(import core/ui :as ui)
(import core/editor :as editor)
(import core/skills :as skills)
(import core/agents-md :as agents-md)
(import core/hooks :as hooks)
(import core/conversation :as conv)
(import core/commands :as commands)
(import core/registers :as reg)

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
  "Execute tool calls from the response content blocks. Returns [assistant-msg tool-results] or nil."
  [content]
  (def tool-calls (filter |(= "tool_use" ($ :type)) content))

  (when (empty? tool-calls)
    (break nil))

  # Build the assistant message to add to conversation
  (def assistant-msg {:role "assistant" :content content})

  # Execute each tool call
  (def tool-results
    (seq [tc :in tool-calls]
      # Render tool call: global hook first, then ui dispatch (custom renderer → built-in default)
      (def hook-handled (hooks/run :render-tool-call (tc :name) (tc :input)))
      (unless hook-handled
        (ui/render-tool-call (tc :name) (tc :input)))
      # tools/dispatch fires :before-tool-call and :after-tool-call hooks internally
      (def result (tools/dispatch (tc :name) (tc :input)))
      # Render tool result: global hook first, then ui dispatch (custom renderer → built-in default)
      (def result-hook-handled (hooks/run :render-tool-result (tc :name) result))
      (unless result-hook-handled
        (ui/render-tool-result (tc :name) result))
      # Build the tool_result message for the API
      (if (or (table? result) (array? result) (tuple? result))
        (do
          (def content-arr
            (if (or (array? result) (tuple? result))
              result
              @[result]))
          {:type "tool_result"
           :tool_use_id (tc :id)
           :content content-arr})
        {:type "tool_result"
         :tool_use_id (tc :id)
         :content (string result)})))

  [assistant-msg {:role "user" :content tool-results}])

(defn- print-text-response [response]
  (def content (get response :content []))
  (each block content
    (when (= "text" (block :type))
      (ui/output-agent (block :text)))))

(defn- build-effective-prompt []
  "Build the system prompt with AGENTS.md and skills snippets."
  (def agents-md-snippet (agents-md/system-prompt-snippet))
  (def skills-snippet (skills/system-prompt-snippet))
  (string system-prompt
          (if (not= "" agents-md-snippet) (string "\n" agents-md-snippet) "")
          (if (not= "" skills-snippet) (string "\n" skills-snippet) "")))

(defn- start-streaming
  "Start a non-blocking streaming API call. Returns the stream context.
   Fires :before-send hook with the conversation before sending."
  [conversation effective-prompt]
  (hooks/run :before-send conversation)
  (ui/stream-start)
  (def stream-ctx
    (api/stream-start
      conversation
      (tools/definitions)
      @{:on-text (fn [text]
          (ui/stream-delta text))
        :on-error (fn [err]
          (ui/output-error (string "Stream error: " err))
          (hooks/run :on-error err))}
      effective-prompt))
  stream-ctx)

(defn- drain-stream
  "Read all available stream lines (non-blocking). Returns :done when stream ends,
   :error on error, or nil when no more data is available right now."
  [parser]
  (var result nil)
  (var keep-going true)
  (while keep-going
    (def line (http/stream-read))
    (cond
      # No data available — return to the event loop
      (nil? line)
      (set keep-going false)

      # Stream finished
      (= :done line)
      (do
        (set result :done)
        (set keep-going false))

      # Error table
      (and (table? line) (= :error (get line :type)))
      (do
        (ui/output-error (string "Stream error: " (get line :message "unknown")))
        (set result :error)
        (set keep-going false))

      # Normal SSE line — feed to parser
      (string? line)
      ((parser :feed) line)))
  result)

(defn run
  "Main agent loop. Uses a unified event loop that handles both terminal
   input and streaming API responses concurrently."
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
    (def loaded-configs (or (reg/get :loaded-configs) @[]))
    (when (not (empty? loaded-configs))
      (ui/output-info (string "  " (length loaded-configs) " config:"))
      (each path loaded-configs
        (ui/output-info (string "    • " path))))

    # Initialize conversation session
    (def sid (conv/init))
    (ui/output-info (string "  session: " sid))

    # Wire up separator status bar
    (ui/set-status-provider
      (fn []
        (string "session: " (conv/get-session-id)
                " │ " (conv/length) " msgs"
                " ≈ " (conv/estimate-tokens) " tokens")))

    # Redraw separator when messages change
    (hooks/add :after-message (fn [msg] (ui/draw-separator)))

    # Initial separator draw with session info
    (ui/draw-separator)

    # State machine
    # :idle       — waiting for user input
    # :streaming  — API stream active, receiving SSE data
    # :tools      — executing tool calls (synchronous)
    (var state :idle)
    (var stream-ctx nil)      # current stream context (parser etc.)
    (var pending-input nil)   # input typed during streaming

    (editor/reset)

    (while true
      # ── Poll terminal events (short timeout when streaming, block when idle) ──
      (def timeout (if (= state :idle) nil 16))
      (def ev (term/read-event timeout))

      # ── Handle terminal event ──
      (when ev
        (def r (editor/handle-event ev))
        (cond
          (= r :quit)
          (do
            # Cancel any active stream
            (when (= state :streaming)
              (http/stream-stop)
              (ui/stream-end))
            (break))

          (string? r)
          (if (= state :idle)
            # Submit immediately
            (when (not= "" r)
              # Check for slash commands first
              (def cmd-result (commands/dispatch r))
              (if (cmd-result :handled)
                (do
                  (ui/output-user r)
                  (def result (cmd-result :result))
                  (when (not= "" result)
                    (each line (string/split "\n" result)
                      (ui/output-info line)))
                  (ui/draw-separator))
                (do
                  (ui/output-user r)
                  (conv/push {:role "user" :content r})
                  (def effective-prompt (build-effective-prompt))
                  (try
                    (do
                      (set stream-ctx (start-streaming (conv/get-messages) effective-prompt))
                      (set state :streaming))
                    ([err]
                      (hooks/run :on-error err)
                      (ui/output-error (string err)))))))
            # During streaming — queue it for later
            (when (not= "" r)
              (set pending-input r)))))

      # ── Drain stream data when streaming ──
      (when (= state :streaming)
        (def parser (stream-ctx :parser))
        (def drain-result (drain-stream parser))

        (when (or (= drain-result :done) (= drain-result :error))
          (ui/stream-end)

          (if (= drain-result :error)
            (do
              (set state :idle)
              (set stream-ctx nil))
            (do
              # Stream finished — get the response
              (def response ((parser :finish)))

              (when (nil? response)
                (ui/output-error "API request failed — nil response")
                (set state :idle)
                (set stream-ctx nil)
                (break))

              # Fire :after-response hook
              (hooks/run :after-response response)

              # Handle tool calls if any
              (def content (get response :content []))
              (def tool-result (handle-tool-calls content))

              (if tool-result
                (do
                  # Add assistant + tool results, start another API call
                  (conv/push (tool-result 0))
                  (conv/push (tool-result 1))
                  (def effective-prompt (build-effective-prompt))
                  (try
                    (do
                      (set stream-ctx (start-streaming (conv/get-messages) effective-prompt))
                      (set state :streaming))
                    ([err]
                      (hooks/run :on-error err)
                      (ui/output-error (string err))
                      (set state :idle)
                      (set stream-ctx nil))))
                (do
                  # No tool calls — response complete
                  (conv/push {:role "assistant" :content content})
                  (set state :idle)
                  (set stream-ctx nil)

                  # If user typed something during streaming, submit it now
                  (when pending-input
                    (ui/output-user pending-input)
                    (conv/push {:role "user" :content pending-input})
                    (set pending-input nil)
                    (def effective-prompt (build-effective-prompt))
                    (try
                      (do
                        (set stream-ctx (start-streaming (conv/get-messages) effective-prompt))
                        (set state :streaming))
                      ([err]
                        (hooks/run :on-error err)
                        (ui/output-error (string err))))))))))))
    ))
