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
(import core/abort :as abort)

(var- system-prompt
  `````
  You are gent, an extensible coding agent built as a lisp machine in Janet (a Lisp).
  You help users by reading files, editing code, running commands, and writing new files.
  Be concise and direct. When you need information, use your tools.

  ## Self-modification with eval_janet

  eval_janet is what makes gent a lisp machine. You have full access to the running agent.
  Use it proactively — don't just answer questions, reprogram yourself when it helps.

  ### Create tools at runtime

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

  ### Introspect your own state

  ```janet
  # What tools are registered?
  (import core/tools :as tools)
  (tools/list-registered)

  # How big is the conversation?
  (import core/conversation :as conv)
  [(conv/length) (conv/estimate-tokens)]

  # What model/config are you using?
  (import core/api :as api)
  (api/get-config)

  # What hooks are active?
  (import core/hooks :as hooks)
  (hooks/list-hooks)

  # Read/write registers (named scratch storage)
  (import core/registers :as reg)
  (reg/set :my-data "saved for later")
  (reg/get :my-data)
  ```

  ### Add hooks to change your own behavior

  ```janet
  (import core/hooks :as hooks)

  # Log all tool calls to a file
  (hooks/add :before-tool-call
    (fn [name input]
      (spit "tool-log.txt"
            (string (os/date) " " name " " (string/format "%q" input) "\n")
            :a)))

  # Guard: refuse to edit certain paths
  (hooks/add :before-tool-call
    (fn [name input]
      (when (and (= name "edit_file")
                 (string/has-prefix? "vendor/" (get input :path "")))
        (error "Refusing to edit vendor/ files"))))
  ```

  ### Register slash commands for the user

  ```janet
  (import core/commands :as commands)

  (commands/register "todo"
    {:description "Show or add todo items"
     :usage "/todo [item]"
     :function (fn [args]
                 (import core/registers :as reg)
                 (var todos (or (reg/get :todos) @[]))
                 (if (= "" args)
                   (string/join (seq [i :range [0 (length todos)]]
                                  (string (+ i 1) ". " (get todos i))) "\n")
                   (do (array/push todos args)
                       (reg/set :todos todos)
                       (string "Added: " args))))})
  ```

  ### Modify the UI

  ```janet
  (import core/ui :as ui)
  # Show more lines in tool results
  (ui/set-tool-result-max-lines 50)
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

# ── Tool execution state ──────────────────────────────────────────
# Tracks async tool execution during the :tools state.

(var- tool-exec @{:tool-calls @[]
                  :content nil
                  :current-idx 0
                  :results @[]
                  :async-handle nil})

(defn- reset-tool-exec
  "Reset tool execution state for a new batch of tool calls."
  [tool-calls content]
  (abort/clear-abort!)
  (put tool-exec :tool-calls tool-calls)
  (put tool-exec :content content)
  (put tool-exec :current-idx 0)
  (put tool-exec :results @[])
  (put tool-exec :async-handle nil))

(defn- tool-result-msg
  "Build a tool_result message for the API."
  [tool-use-id result]
  (if (or (table? result) (array? result) (tuple? result))
    (do
      (def content-arr
        (if (or (array? result) (tuple? result))
          result
          @[result]))
      {:type "tool_result"
       :tool_use_id tool-use-id
       :content content-arr})
    {:type "tool_result"
     :tool_use_id tool-use-id
     :content (string result)}))

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
  (ui/spinner-start "thinking…")
  (def stream-ctx
    (api/stream-start
      conversation
      (tools/definitions)
      @{:on-text (fn [text]
          (when (ui/spinner-active?)
            (ui/spinner-stop))
          (ui/stream-delta text))
        :on-error (fn [err]
          (ui/spinner-stop)
          (ui/output-error (string "Stream error: " err))
          (hooks/run :on-error err))}
      effective-prompt))
  stream-ctx)

(defn- drain-stream
  "Read all available stream lines (non-blocking). Returns :done when stream ends,
   :error on error, or nil when no more data is available right now."
  [parser &opt stream-id]
  (var result nil)
  (var keep-going true)
  (while keep-going
    (def line (http/stream-read stream-id))
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
    (ui/output "")  # blank line after startup info

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
    # :tools      — executing tool calls (async polling for bash, sync for others)
    (var state :idle)
    (var stream-ctx nil)      # current stream context (parser etc.)
    # Steering / follow-up queues (à la pi)
    # - steering-queue: messages typed during :tools → interrupt, skip remaining tools
    # - followup-queue: messages typed during :streaming → wait until turn finishes
    (var steering-queue @[])
    (var followup-queue @[])

    (defn- eval-janet-inline [code]
      "Evaluate Janet code from the prompt and display the result."
      (try
        (do
          (def result (eval-string code))
          (def result-str
            (if (or (string? result) (number? result) (boolean? result) (nil? result))
              (string result)
              (string/format "%q" result)))
          (ui/output-eval code result-str))
        ([err]
          (ui/output-eval code nil)
          (ui/output-error (string err))))
      (ui/draw-separator)
      (editor/redraw))

    (defn- start-next-tool []
      "Start executing the next tool in the queue. If all tools are done,
       push results to conversation and start a new stream.
       Checks abort flag — if set, skips remaining tools."
      (def idx (tool-exec :current-idx))

      # Check abort flag — skip remaining tools
      (when (abort/aborted?)
        (ui/spinner-stop)
        (ui/output-info "— remaining tools skipped —")
        (def assistant-msg {:role "assistant" :content (tool-exec :content)})
        (def tool-msg {:role "user" :content (tool-exec :results)})
        (conv/push assistant-msg)
        (when (not (empty? (tool-exec :results)))
          (conv/push tool-msg))

        # Process steering messages — user input that interrupted tools
        (if (not (empty? steering-queue))
          (do
            (def steer-msg (string/join steering-queue "\n"))
            (array/clear steering-queue)
            (ui/output-user steer-msg)
            (conv/push {:role "user" :content steer-msg})
            (def effective-prompt (build-effective-prompt))
            (try
              (do
                (set stream-ctx (start-streaming (conv/get-messages) effective-prompt))
                (set state :streaming))
              ([err]
                (hooks/run :on-error err)
                (ui/output-error (string err))
                (set state :idle)
                (set stream-ctx nil)
                (editor/redraw))))
          (do
            (set state :idle)
            (set stream-ctx nil)
            (editor/redraw)))
        (break))

      (if (>= idx (length (tool-exec :tool-calls)))
        # ── All tools done ──
        (do
          (def assistant-msg {:role "assistant" :content (tool-exec :content)})
          (def tool-msg {:role "user" :content (tool-exec :results)})
          (conv/push assistant-msg)
          (conv/push tool-msg)
          (def effective-prompt (build-effective-prompt))
          (try
            (do
              (set stream-ctx (start-streaming (conv/get-messages) effective-prompt))
              (set state :streaming))
            ([err]
              (hooks/run :on-error err)
              (ui/output-error (string err))
              (set state :idle)
              (set stream-ctx nil)
              (editor/redraw))))

        # ── Execute current tool ──
        (do
          (def tc (get (tool-exec :tool-calls) idx))
          (def name (tc :name))
          (def input (tc :input))

          (ui/spinner-start (string "running " name "…"))

          # Render tool call (hook then fallback)
          (def hook-handled (hooks/run :render-tool-call name input))
          (unless hook-handled
            (ui/render-tool-call name input))

          # Dispatch the tool — may return sync result or async handle
          (def result (tools/dispatch name input))

          (if (tools/async? result)
            # ── Async tool execution — store handle, poll in event loop ──
            (put tool-exec :async-handle result)

            # ── Sync result — render immediately and move to next tool ──
            (do
              (ui/spinner-stop)
              (def result-hook-handled (hooks/run :render-tool-result name result))
              (unless result-hook-handled
                (ui/render-tool-result name result))
              (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
              (put tool-exec :current-idx (+ idx 1))
              # Recurse to start next tool immediately (sync tools are fast)
              (start-next-tool))))))

    (defn- finish-current-async-tool [result]
      "Called when the current async tool completes with a result string."
      (def idx (tool-exec :current-idx))
      (def tc (get (tool-exec :tool-calls) idx))

      (hooks/run :after-tool-call (tc :name) (tc :input) result)
      (ui/spinner-stop)
      (def result-hook-handled (hooks/run :render-tool-result (tc :name) result))
      (unless result-hook-handled
        (ui/render-tool-result (tc :name) result))

      (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
      (put tool-exec :async-handle nil)
      (put tool-exec :current-idx (+ idx 1))
      (start-next-tool))

    (editor/reset)

    (while true
      # ── Poll terminal events (short timeout when streaming/tools, block when idle) ──
      (def timeout (if (= state :idle) nil 16))
      (def ev (term/read-event timeout))

      # ── Handle terminal event ──
      (when ev
        (def r (editor/handle-event ev))
        (cond
          (= r :quit)
          (do
            # Cancel any active stream or process
            (when (= state :streaming)
              (http/stream-stop (get stream-ctx :stream-id))
              (ui/stream-end)
              (ui/spinner-stop))
            (when (= state :tools)
              (when (tool-exec :async-handle)
                ((get (tool-exec :async-handle) :cancel)))
              (ui/spinner-stop))
            (break))

          (= r :stop)
          (cond
            (= state :streaming)
            (do
              # Cancel the active stream
              (http/stream-stop (get stream-ctx :stream-id))
              (ui/stream-end)
              (ui/spinner-stop)
              (ui/output-info "— stopped —")
              # Collect whatever partial response we have and save it
              (def parser (stream-ctx :parser))
              (def response (try ((parser :finish)) ([_] nil)))
              (when (and response (get response :content))
                (conv/push {:role "assistant" :content (get response :content)}))
              (set state :idle)
              (set stream-ctx nil)
              (array/clear followup-queue)
              (ui/draw-separator)
              (editor/redraw))

            (= state :tools)
            (do
              # Set abort flag so remaining tools are skipped
              (abort/abort!)
              # Cancel running async tool if active
              (when (tool-exec :async-handle)
                ((get (tool-exec :async-handle) :cancel))
                (put tool-exec :async-handle nil))
              (ui/spinner-stop)
              (ui/output-info "— tools cancelled —")
              # Save partial results: push assistant message with content so far
              (conv/push {:role "assistant" :content (tool-exec :content)})
              (set state :idle)
              (set stream-ctx nil)
              (array/clear steering-queue)
              (array/clear followup-queue)
              (ui/draw-separator)
              (editor/redraw)))

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
            # During streaming — queue for follow-up after turn
            # During tools — queue for steering (interrupt tool execution)
            (when (not= "" r)
              (if (= state :tools)
                (do
                  (array/push steering-queue r)
                  # Trigger abort to skip remaining tools
                  (abort/abort!)
                  (when (tool-exec :async-handle)
                    ((get (tool-exec :async-handle) :cancel))
                    (put tool-exec :async-handle nil))
                  (ui/spinner-stop)
                  (ui/output-info "— interrupted by user input —"))
                (array/push followup-queue r))))

          # Janet eval — comma prefix or Alt-Enter
          (and (tuple? r) (= :eval (first r)))
          (do
            (def code (get r 1))
            (when (and code (not= "" code))
              (eval-janet-inline code)))))

      # ── Drain stream data when streaming ──
      (when (= state :streaming)
        (ui/spinner-tick)
        (def parser (stream-ctx :parser))
        (def drain-result (drain-stream parser (get stream-ctx :stream-id)))

        (when (or (= drain-result :done) (= drain-result :error))
          (ui/stream-end)
          (ui/spinner-stop)

          (if (= drain-result :error)
            (do
              (set state :idle)
              (set stream-ctx nil)
              (editor/redraw))
            (do
              # Stream finished — get the response
              (def response ((parser :finish)))

              (when (nil? response)
                (ui/output-error "API request failed — nil response")
                (set state :idle)
                (set stream-ctx nil)
                (editor/redraw)
                (break))

              # Fire :after-response hook
              (hooks/run :after-response response)

              # Check for tool calls
              (def content (get response :content []))
              (def tool-calls (filter |(= "tool_use" ($ :type)) content))

              (if (not (empty? tool-calls))
                (do
                  # Enter :tools state — execute tools asynchronously
                  (reset-tool-exec tool-calls content)
                  (set state :tools)
                  (start-next-tool))
                (do
                  # No tool calls — response complete
                  (conv/push {:role "assistant" :content content})
                  (set state :idle)
                  (set stream-ctx nil)
                  (editor/redraw)

                  # If user typed something during streaming, submit the follow-up
                  (when (not (empty? followup-queue))
                    (def followup (string/join followup-queue "\n"))
                    (array/clear followup-queue)
                    (ui/output-user followup)
                    (conv/push {:role "user" :content followup})
                    (def effective-prompt (build-effective-prompt))
                    (try
                      (do
                        (set stream-ctx (start-streaming (conv/get-messages) effective-prompt))
                        (set state :streaming))
                      ([err]
                        (hooks/run :on-error err)
                        (ui/output-error (string err)))))))))))

      # ── Poll tool execution when in :tools state ──
      (when (= state :tools)
        (ui/spinner-tick)
        (when (tool-exec :async-handle)
          (def poll-result ((get (tool-exec :async-handle) :poll)))
          (when poll-result
            (def [event-type event-data] poll-result)
            (cond
              (= event-type :done)
              (finish-current-async-tool event-data)

              (= event-type :error)
              (do
                (def idx (tool-exec :current-idx))
                (def tc (get (tool-exec :tool-calls) idx))
                (def result (string "Error: " event-data))
                (hooks/run :after-tool-call (tc :name) (tc :input) result)
                (ui/spinner-stop)
                (ui/render-tool-result (tc :name) result)
                (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
                (put tool-exec :async-handle nil)
                (put tool-exec :current-idx (+ idx 1))
                (start-next-tool))))))
    )))
