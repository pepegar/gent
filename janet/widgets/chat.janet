# widgets/chat.janet — The agent chat widget.
#
# Manages the agent state machine: idle → streaming → tools → streaming → ...
# Owns: API streaming, tool execution, conversation flow, output rendering.
#
# Phase 3: Full buffer-based rendering with scrollback.
# All output goes into a scrollback array. The visible window is rendered
# into a tui/buffer each frame. No scroll regions.

(import core/tools :as tools)
(import core/api :as api)
(import core/ui :as ui)
(import core/hooks :as hooks)
(import core/conversation :as conv)
(import core/abort :as abort)
(import core/agents-md :as agents-md)
(import core/skills :as skills)
(import core/widget :as widget)
(import core/editor :as editor)
(import tui)

# ── System prompt ──────────────────────────────────────────────

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

# ── State ──────────────────────────────────────────────────────

(var- mode :idle)          # :idle | :streaming | :tools
(var- stream-ctx nil)
(var- steering-queue @[])
(var- followup-queue @[])

(var- tool-exec @{:tool-calls @[]
                  :content nil
                  :current-idx 0
                  :results @[]
                  :async-handle nil})

# ── Scrollback buffer ─────────────────────────────────────────
# Each entry is a table: {:text "..." :style style-struct}
# A "line" is one row of visible output.

(var- scrollback @[])
(var- scroll-offset 0)     # 0 = pinned to bottom, >0 = scrolled up
(var- max-scrollback 10000)

# ── State accessors (for testing and introspection) ────────────

(defn get-scrollback
  "Return the scrollback array (mutable reference)."
  [] scrollback)

(defn get-scroll-offset
  "Return the current scroll offset (0 = pinned to bottom)."
  [] scroll-offset)

(defn set-scroll-offset
  "Set the scroll offset directly."
  [n] (set scroll-offset n))

(defn get-mode
  "Return the current chat mode (:idle, :streaming, or :tools)."
  [] mode)

(defn reset-state
  "Reset chat state for testing. Clears scrollback, resets mode to idle."
  []
  (array/clear scrollback)
  (set scroll-offset 0)
  (set mode :idle)
  (set stream-ctx nil)
  (array/clear steering-queue)
  (array/clear followup-queue))

# ── Color scheme (matches core/ui) ────────────────────────────

(def- colors
  @{:user-label   (tui/style :fg [:rgb 39 135 255] :bold true)
    :agent-label  (tui/style :fg [:rgb 214 135 0] :bold true)
    :tool-label   (tui/style :fg [:rgb 78 175 78] :bold true)
    :error-label  (tui/style :fg [:rgb 196 50 50] :bold true)
    :separator    (tui/style :fg (tui/color-indexed 240))
    :eval-linenum (tui/style :fg [:rgb 140 140 160])
    :eval-border  (tui/style :fg [:rgb 180 180 190])
    :eval-code    (tui/style :fg [:rgb 30 30 30] :bg [:rgb 255 255 255])
    :tool-bg      (tui/style :fg (tui/color-indexed 240))
    :diff-red-fg  (tui/style :fg [:rgb 210 100 100] :bg [:rgb 80 20 20])
    :diff-green-fg (tui/style :fg [:rgb 114 175 114] :bg [:rgb 20 80 20])
    :reset        (tui/style)})

# ── Output helpers (scrollback-based) ─────────────────────────

(defn- push-line
  "Add a styled line to the scrollback. Marks widget dirty.
   When scrolled up (offset > 0), increments offset so the visible
   window stays pinned to the same content."
  [text &opt style]
  (default style (tui/style))
  (array/push scrollback @{:text text :style style})
  (when (> scroll-offset 0) (++ scroll-offset))
  # Cap scrollback size
  (when (> (length scrollback) max-scrollback)
    (array/remove scrollback 0 (- (length scrollback) max-scrollback)))
  (widget/mark-dirty :chat))

(defn- push-raw-line
  "Add a pre-formatted line (array of spans) to the scrollback.
   When scrolled up, increments offset to keep the view stable."
  [spans]
  (array/push scrollback @{:spans spans})
  (when (> scroll-offset 0) (++ scroll-offset))
  (when (> (length scrollback) max-scrollback)
    (array/remove scrollback 0 (- (length scrollback) max-scrollback)))
  (widget/mark-dirty :chat))

(defn- word-wrap
  "Word-wrap a plain text line to max-width. Returns array of strings."
  [text max-width]
  (if (<= (length text) max-width)
    @[text]
    (do
      (def result @[])
      (var start 0)
      (while (< start (length text))
        (def remaining (- (length text) start))
        (if (<= remaining max-width)
          (do (array/push result (string/slice text start))
              (set start (length text)))
          (do
            (def chunk-end (+ start max-width))
            (var break-at nil)
            (for i 0 max-width
              (def pos (- chunk-end 1 i))
              (when (= (get text pos) (chr " "))
                (set break-at pos)
                (break)))
            (if (and break-at (> break-at start))
              (do (array/push result (string/slice text start break-at))
                  (set start (+ break-at 1)))
              (do (array/push result (string/slice text start chunk-end))
                  (set start chunk-end))))))
      result)))

# ── Formatted output ──────────────────────────────────────────

(defn output
  "Add a plain line to scrollback."
  [text]
  (push-line text))

(defn output-info [text]
  (push-line text (colors :separator)))

(defn output-error [text]
  (push-raw-line
    @[@{:text " error " :style (colors :error-label)}
      @{:text (string " " text) :style (tui/style)}]))

(defn output-user [text]
  (push-raw-line
    @[@{:text " you " :style (colors :user-label)}
      @{:text (string " " text) :style (tui/style)}]))

(defn output-agent [lines]
  "Add agent response to scrollback with word-wrapping."
  (def w (widget/get-widget :chat))
  (def max-width
    (if (and w (w :rect))
      (max 20 (- ((w :rect) :width) 8))
      72))
  (def parts (string/split "\n" lines))
  (var first true)
  (each line parts
    (if (= "" line)
      (push-line "")
      (do
        (def wrapped (word-wrap line max-width))
        (each wl wrapped
          (if first
            (do
              (push-raw-line
                @[@{:text " gent " :style (colors :agent-label)}
                  @{:text (string " " wl) :style (tui/style)}])
              (set first false))
            (push-line (string "       " wl))))))))

(defn output-tool [name &opt detail]
  (push-raw-line
    @[@{:text (string "  ▸ " name) :style (colors :tool-label)}
      @{:text (if detail (string " " detail) "") :style (colors :separator)}]))

(defn output-eval-janet [code]
  "Render eval_janet code with line numbers."
  (def lines (string/split "\n" code))
  (var start 0)
  (var end (length lines))
  (while (and (< start end) (= "" (string/trim (get lines start ""))))
    (++ start))
  (while (and (> end start) (= "" (string/trim (get lines (- end 1) ""))))
    (-- end))
  (output-tool "eval_janet")
  (when (>= start end) (break))
  (def trimmed (array/slice lines start end))
  (def num-lines (length trimmed))
  (def num-width (max 2 (length (string num-lines))))
  (for i 0 num-lines
    (def linenum (string/format (string "%" num-width "d") (+ i 1)))
    (def code-line (get trimmed i ""))
    (push-raw-line
      @[@{:text (string "    " linenum " ") :style (colors :eval-linenum)}
        @{:text "│" :style (colors :eval-border)}
        @{:text (string " " code-line) :style (colors :eval-code)}])))

(defn output-edit-file [input]
  "Render edit_file with diff display."
  (def path (get input :path ""))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))
  (def is-create (= "" old-str))
  (def max-diff-lines 8)

  (if is-create
    (push-raw-line
      @[@{:text "  ▸ edit_file" :style (colors :tool-label)}
        @{:text (string " " path " ") :style (colors :separator)}
        @{:text "(new file)" :style (colors :tool-label)}])
    (push-raw-line
      @[@{:text "  ▸ edit_file" :style (colors :tool-label)}
        @{:text (string " " path) :style (colors :separator)}]))

  (when (not= "" old-str)
    (def old-lines (string/split "\n" old-str))
    (def show-n (min (length old-lines) max-diff-lines))
    (for i 0 show-n
      (push-line (string "    - " (get old-lines i "")) (colors :diff-red-fg)))
    (when (> (length old-lines) max-diff-lines)
      (push-line (string "      … " (- (length old-lines) max-diff-lines) " more lines") (colors :separator))))

  (when (not= "" new-str)
    (def new-lines (string/split "\n" new-str))
    (def show-n (min (length new-lines) max-diff-lines))
    (for i 0 show-n
      (push-line (string "    + " (get new-lines i "")) (colors :diff-green-fg)))
    (when (> (length new-lines) max-diff-lines)
      (push-line (string "      … " (- (length new-lines) max-diff-lines) " more lines") (colors :separator)))))

(var- tool-result-max-lines 10)

(defn set-tool-result-max-lines [n]
  (set tool-result-max-lines n))

(defn output-tool-result [text]
  (def lines (string/split "\n" text))
  (def total (length lines))
  (def show-lines (min total tool-result-max-lines))
  (for i 0 show-lines
    (def line (get lines i ""))
    (push-line (string "    " line) (colors :separator)))
  (when (> total tool-result-max-lines)
    (push-line (string "    … " (- total tool-result-max-lines) " more lines omitted") (colors :separator))))

# ── Pluggable tool renderers ──────────────────────────────────

(var- tool-renderers @{})
(var- tool-result-renderers @{})

(defn set-tool-renderer [name renderer]
  (if renderer (put tool-renderers name renderer)
    (put tool-renderers name nil)))

(defn set-tool-result-renderer [name renderer]
  (if renderer (put tool-result-renderers name renderer)
    (put tool-result-renderers name nil)))

(defn render-tool-call [name input]
  (def custom (get tool-renderers name))
  (if custom
    (custom input)
    (cond
      (= "eval_janet" name) (output-eval-janet (get input :code ""))
      (= "edit_file" name) (output-edit-file input)
      (output-tool name (json/encode input)))))

(defn render-tool-result [name result]
  (def custom (get tool-result-renderers name))
  (if custom
    (custom result)
    (if (or (table? result) (array? result) (tuple? result))
      (output-tool-result (string "[Image: " (get-in result [:source :media_type] "unknown") "]"))
      (output-tool-result (string result)))))

(defn output-eval [code result]
  "Display an inline Janet eval."
  (push-raw-line
    @[@{:text " eval " :style (colors :tool-label)}
      @{:text (string " " code) :style (colors :separator)}])
  (when (and result (not= "" result))
    (each line (string/split "\n" result)
      (push-raw-line
        @[@{:text "    => " :style (colors :tool-label)}
          @{:text line :style (tui/style)}]))))

# ── Streaming output ──────────────────────────────────────────

(var- stream-state @{:active false :line-buf @"" :first true})

(defn- stream-start-output []
  (put stream-state :active true)
  (put stream-state :first true)
  (buffer/clear (stream-state :line-buf)))

(defn- stream-delta [text]
  (def buf (stream-state :line-buf))
  (def w (widget/get-widget :chat))
  (def max-width
    (if (and w (w :rect))
      (max 20 (- ((w :rect) :width) 8))
      72))
  (each byte text
    (if (= byte (chr "\n"))
      (do
        (def line (string buf))
        (buffer/clear buf)
        (if (= "" line)
          (push-line "")
          (do
            (def wrapped (word-wrap line max-width))
            (each wl wrapped
              (if (stream-state :first)
                (do
                  (push-raw-line
                    @[@{:text " gent " :style (colors :agent-label)}
                      @{:text (string " " wl) :style (tui/style)}])
                  (put stream-state :first false))
                (push-line (string "       " wl)))))))
      (buffer/push buf byte)))
  # Mark dirty so the partial line in the buffer gets rendered each frame
  (widget/mark-dirty :chat))

(defn- stream-end-output []
  (def buf (stream-state :line-buf))
  (def w (widget/get-widget :chat))
  (def max-width
    (if (and w (w :rect))
      (max 20 (- ((w :rect) :width) 8))
      72))
  (when (> (length buf) 0)
    (def line (string buf))
    (def wrapped (word-wrap line max-width))
    (each wl wrapped
      (if (stream-state :first)
        (do
          (push-raw-line
            @[@{:text " gent " :style (colors :agent-label)}
              @{:text (string " " wl) :style (tui/style)}])
          (put stream-state :first false))
        (push-line (string "       " wl)))))
  (buffer/clear buf)
  (put stream-state :active false)
  (put stream-state :first true))

# ── Spinner ────────────────────────────────────────────────────
# Spinner renders into the last line of the chat area (not the editor row).

(def- spinner-frames ["⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"])
(var- spinner-state @{:active false :frame 0 :message ""})

(defn- spinner-start [msg]
  (put spinner-state :active true)
  (put spinner-state :frame 0)
  (put spinner-state :message msg)
  (widget/mark-dirty :chat))

(defn- spinner-active? [] (spinner-state :active))

(defn- spinner-tick []
  (when (spinner-state :active)
    (put spinner-state :frame (% (+ (spinner-state :frame) 1) (length spinner-frames)))
    (widget/mark-dirty :chat)))

(defn- spinner-stop []
  (when (spinner-state :active)
    (put spinner-state :active false)
    (widget/mark-dirty :chat)))

# ── Core helpers ───────────────────────────────────────────────

(defn- build-effective-prompt []
  (def agents-md-snippet (agents-md/system-prompt-snippet))
  (def skills-snippet (skills/system-prompt-snippet))
  (string system-prompt
          (if (not= "" agents-md-snippet) (string "\n" agents-md-snippet) "")
          (if (not= "" skills-snippet) (string "\n" skills-snippet) "")))

(defn- reset-tool-exec [tool-calls content]
  (abort/clear-abort!)
  (put tool-exec :tool-calls tool-calls)
  (put tool-exec :content content)
  (put tool-exec :current-idx 0)
  (put tool-exec :results @[])
  (put tool-exec :async-handle nil))

(defn- tool-result-msg [tool-use-id result]
  (if (or (table? result) (array? result) (tuple? result))
    (do
      (def content-arr
        (if (or (array? result) (tuple? result)) result @[result]))
      {:type "tool_result" :tool_use_id tool-use-id :content content-arr})
    {:type "tool_result" :tool_use_id tool-use-id :content (string result)}))

(defn- start-streaming [conversation effective-prompt]
  (hooks/run :before-send conversation)
  (stream-start-output)
  (spinner-start "thinking…")
  (def ctx
    (api/stream-start
      conversation
      (tools/definitions)
      @{:on-text (fn [text]
          (when (spinner-active?) (spinner-stop))
          (stream-delta text))
        :on-error (fn [err]
          (spinner-stop)
          (output-error (string "Stream error: " err))
          (hooks/run :on-error err))}
      effective-prompt))
  (set stream-ctx ctx)
  (set mode :streaming))

(defn- drain-stream []
  (def parser (stream-ctx :parser))
  (def stream-id (get stream-ctx :stream-id))
  (var result nil)
  (var keep-going true)
  (var budget 32)
  (while (and keep-going (> budget 0))
    (-- budget)
    (def line (http/stream-read stream-id))
    (cond
      (nil? line) (set keep-going false)
      (= :done line) (do (set result :done) (set keep-going false))
      (and (table? line) (= :error (get line :type)))
      (do (output-error (string "Stream error: " (get line :message "unknown")))
          (set result :error) (set keep-going false))
      (string? line) ((parser :feed) line)))
  result)

# ── Tool execution ─────────────────────────────────────────────

(var- start-next-tool nil)

(defn- finish-current-async-tool [result]
  (def idx (tool-exec :current-idx))
  (def tc (get (tool-exec :tool-calls) idx))
  (hooks/run :after-tool-call (tc :name) (tc :input) result)
  (spinner-stop)
  (def result-hook-handled (hooks/run :render-tool-result (tc :name) result))
  (unless result-hook-handled (render-tool-result (tc :name) result))
  (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
  (put tool-exec :async-handle nil)
  (put tool-exec :current-idx (+ idx 1))
  (start-next-tool))

(defn- enter-idle []
  (set mode :idle)
  (set stream-ctx nil)
  (widget/mark-dirty :editor))

(defn- push-tool-results-and-stream []
  (def assistant-msg {:role "assistant" :content (tool-exec :content)})
  (def tool-msg {:role "user" :content (tool-exec :results)})
  (conv/push assistant-msg)
  (when (not (empty? (tool-exec :results)))
    (conv/push tool-msg))
  (def effective-prompt (build-effective-prompt))
  (try
    (start-streaming (conv/get-messages) effective-prompt)
    ([err]
      (hooks/run :on-error err)
      (output-error (string err))
      (enter-idle))))

(defn- process-steering-or-idle []
  (if (not (empty? steering-queue))
    (do
      (def steer-msg (string/join steering-queue "\n"))
      (array/clear steering-queue)
      (output-user steer-msg)
      (conv/push {:role "user" :content steer-msg})
      (def effective-prompt (build-effective-prompt))
      (try
        (start-streaming (conv/get-messages) effective-prompt)
        ([err]
          (hooks/run :on-error err)
          (output-error (string err))
          (enter-idle))))
    (enter-idle)))

(set start-next-tool
  (fn []
    (var keep-going true)
    (while keep-going
      (set keep-going false)
      (def idx (tool-exec :current-idx))
      (when (abort/aborted?)
        (spinner-stop)
        (output-info "— remaining tools skipped —")
        
        # Check if we have incomplete tool calls that would cause API errors
        (def tool-calls (tool-exec :tool-calls))
        (def completed-tools (tool-exec :results))
        (def has-incomplete (and (not (empty? tool-calls)) 
                                (< (length completed-tools) (length tool-calls))))
        
        (if has-incomplete
          # Don't push incomplete assistant message - just handle steering
          (when (not (empty? steering-queue))
            (process-steering-or-idle))
          # All tools completed - safe to push results and stream
          (do
            (push-tool-results-and-stream)
            (when (= mode :idle) (break))
            (when (not (empty? steering-queue))
              (process-steering-or-idle))))
        (break))

      (if (>= idx (length (tool-exec :tool-calls)))
        (push-tool-results-and-stream)
        (do
          (def tc (get (tool-exec :tool-calls) idx))
          (def name (tc :name))
          (def input (tc :input))
          (spinner-start (string "running " name "…"))
          (def hook-handled (hooks/run :render-tool-call name input))
          (unless hook-handled (render-tool-call name input))
          (def result (tools/dispatch name input))
          (if (tools/async? result)
            (put tool-exec :async-handle result)
            (do
              (spinner-stop)
              (def result-hook-handled (hooks/run :render-tool-result name result))
              (unless result-hook-handled (render-tool-result name result))
              (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
              (put tool-exec :current-idx (+ idx 1))
              (set keep-going true))))))))

(defn- handle-stream-done []
  (stream-end-output)
  (spinner-stop)
  (def parser (stream-ctx :parser))
  (def response ((parser :finish)))
  (when (nil? response)
    (output-error "API request failed — nil response")
    (enter-idle)
    (break))
  (hooks/run :after-response response)
  (def content (get response :content []))
  (def tool-calls (filter |(= "tool_use" ($ :type)) content))
  (if (not (empty? tool-calls))
    (do
      (reset-tool-exec tool-calls content)
      (set mode :tools)
      (start-next-tool))
    (do
      (conv/push {:role "assistant" :content content})
      (enter-idle)
      (when (not (empty? followup-queue))
        (def followup (string/join followup-queue "\n"))
        (array/clear followup-queue)
        (output-user followup)
        (conv/push {:role "user" :content followup})
        (def effective-prompt (build-effective-prompt))
        (try
          (start-streaming (conv/get-messages) effective-prompt)
          ([err]
            (hooks/run :on-error err)
            (output-error (string err))))))))

# ── Tool cancellation fix ─────────────────────────────────────

(defn- handle-cancelled-tool-calls
  "When tool calls are cancelled, we need to either remove the incomplete
   assistant message or add synthetic tool_result blocks to prevent API errors.
   
   This function checks if the last message contains tool_use blocks without 
   corresponding tool_result blocks and fixes the conversation history."
  []
  (def messages (conv/get-messages))
  (def last-msg (if (> (length messages) 0) (last messages) nil))
  
  # Check if last message is an assistant message with tool_use content
  (when (and last-msg (= (get last-msg :role) "assistant"))
    (def content (get last-msg :content []))
    (def tool-uses (filter |(= "tool_use" ($ :type)) content))
    
    (when (not (empty? tool-uses))
      # We have tool_use blocks without results - rollback the incomplete message
      (conv/rollback 1))))

# ── Public API ─────────────────────────────────────────────────

(defn active? []
  (not= mode :idle))

(defn submit [text]
  (cond
    (= mode :idle)
    (do
      (output-user text)
      (conv/push {:role "user" :content text})
      (def effective-prompt (build-effective-prompt))
      (try
        (start-streaming (conv/get-messages) effective-prompt)
        ([err]
          (hooks/run :on-error err)
          (output-error (string err)))))
    (= mode :streaming)
    (array/push followup-queue text)
    (= mode :tools)
    (do
      (array/push steering-queue text)
      (abort/abort!)
      (when (tool-exec :async-handle)
        ((get (tool-exec :async-handle) :cancel))
        (put tool-exec :async-handle nil))
      (spinner-stop)
      (output-info "— interrupted by user input —"))))

(defn stop []
  (cond
    (= mode :streaming)
    (do
      (http/stream-stop (get stream-ctx :stream-id))
      (stream-end-output)
      (spinner-stop)
      (output-info "— stopped —")
      (def parser (stream-ctx :parser))
      (def response (try ((parser :finish)) ([_] nil)))
      (when (and response (get response :content))
        (conv/push {:role "assistant" :content (get response :content)}))
      (array/clear followup-queue)
      (enter-idle)
      (widget/mark-dirty :separator))
    (= mode :tools)
    (do
      (abort/abort!)
      (when (tool-exec :async-handle)
        ((get (tool-exec :async-handle) :cancel))
        (put tool-exec :async-handle nil))
      (spinner-stop)
      (output-info "— tools cancelled —")
      (array/clear steering-queue)
      (array/clear followup-queue)
      (enter-idle)
      (widget/mark-dirty :separator))))

(defn cleanup []
  (when (= mode :streaming)
    (http/stream-stop (get stream-ctx :stream-id))
    (stream-end-output)
    (spinner-stop))
  (when (= mode :tools)
    (when (tool-exec :async-handle)
      ((get (tool-exec :async-handle) :cancel)))
    (spinner-stop)))

(defn tick []
  (when (= mode :streaming)
    (spinner-tick)
    (def drain-result (drain-stream))
    (when (= drain-result :done) (handle-stream-done))
    (when (= drain-result :error)
      (stream-end-output)
      (spinner-stop)
      (enter-idle)))
  (when (= mode :tools)
    (spinner-tick)
    (when (tool-exec :async-handle)
      (def poll-result ((get (tool-exec :async-handle) :poll)))
      (when poll-result
        (def [event-type event-data] poll-result)
        (cond
          (= event-type :done) (finish-current-async-tool event-data)
          (= event-type :error)
          (do
            (def idx (tool-exec :current-idx))
            (def tc (get (tool-exec :tool-calls) idx))
            (def result (string "Error: " event-data))
            (hooks/run :after-tool-call (tc :name) (tc :input) result)
            (spinner-stop)
            (render-tool-result (tc :name) result)
            (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
            (put tool-exec :async-handle nil)
            (put tool-exec :current-idx (+ idx 1))
            (start-next-tool)))))))

# ── Rendering ──────────────────────────────────────────────────

(defn- line-to-visual-rows
  "Convert a scrollback line into an array of visual rows.
   Each visual row is an array of {:text :style} spans that fit within width.
   Lines that exceed width wrap to additional rows."
  [line width]
  (def rows @[])
  (var current-row @[])
  (var col 0)

  (defn- flush-row []
    (when (> (length current-row) 0)
      (array/push rows (array/slice current-row))
      (array/clear current-row)
      (set col 0)))

  (defn- add-text-chars [text style]
    (var ci 0)
    (while (< ci (length text))
      (when (>= col width)
        (flush-row))
      (def byte (get text ci))
      (def char-len
        (cond (< byte 0x80) 1 (< byte 0xE0) 2 (< byte 0xF0) 3 4))
      (def cend (min (+ ci char-len) (length text)))
      (def ch (string/slice text ci cend))
      (array/push current-row @{:text ch :style style})
      (++ col)
      (set ci cend)))

  (if (line :spans)
    (each span (line :spans)
      (def text (span :text))
      (def st (or (span :style) (tui/style)))
      (add-text-chars text st))
    (do
      (def text (or (line :text) ""))
      (def st (or (line :style) (tui/style)))
      (add-text-chars text st)))

  # Flush any remaining content
  (when (> (length current-row) 0)
    (array/push rows (array/slice current-row)))

  # Empty line still takes one visual row
  (when (= 0 (length rows))
    (array/push rows @[]))

  rows)

(defn- count-visual-rows
  "Count how many visual rows a scrollback line occupies at given width."
  [line width]
  (length (line-to-visual-rows line width)))

(defn- render-scrollback
  "Render the visible window of scrollback into a tui/buffer.
   Lines that exceed the viewport width wrap to the next visual row."
  [rect buf]
  (def height (rect :height))
  (def width (rect :width))
  (def total (length scrollback))

  # Leave room for spinner at bottom if active
  (def has-partial (and (stream-state :active) (> (length (stream-state :line-buf)) 0)))
  (def reserved-bottom (+ (if (spinner-active?) 1 0) (if has-partial 1 0)))
  (def render-height (- height reserved-bottom))

  # Build visual rows from the bottom up until we fill the viewport.
  # We walk backwards from (total - scroll-offset) and expand each
  # scrollback line into its wrapped visual rows.
  (def end-idx (max 0 (- total scroll-offset)))
  (def visual-rows @[])

  (var line-idx (- end-idx 1))
  (while (and (>= line-idx 0) (< (length visual-rows) render-height))
    (def line (get scrollback line-idx))
    (def rows (line-to-visual-rows line width))
    # Prepend rows in reverse so they end up in order
    (var ri (- (length rows) 1))
    (while (and (>= ri 0) (< (length visual-rows) render-height))
      (array/push visual-rows (get rows ri))
      (-- ri))
    (-- line-idx))

  # visual-rows is in reverse order — flip it
  (def ordered (reverse visual-rows))
  (def visible-count (length ordered))

  # Bottom-align: if content doesn't fill the viewport, offset downward
  (def y-offset (- render-height visible-count))

  # Render each visual row
  (for i 0 visible-count
    (def row (get ordered i))
    (def y (+ (rect :y) y-offset i))
    (var col (rect :x))
    (each cell row
      (when (>= col (+ (rect :x) width)) (break))
      (tui/buffer-set-char buf col y (cell :text) (cell :style))
      (++ col)))

  # Render the in-progress streaming line (partial line not yet newline-terminated)
  (when has-partial
    (def partial-text (string (stream-state :line-buf)))
    # Render just below the scrollback content (in the reserved area)
    (def partial-y (+ (rect :y) y-offset visible-count))
    (when (< partial-y (+ (rect :y) height))
      (if (stream-state :first)
        (do
          (tui/buffer-set-string buf (rect :x) partial-y " gent " (colors :agent-label))
          (tui/buffer-set-string buf (+ (rect :x) 6) partial-y (string " " partial-text) (tui/style)))
        (tui/buffer-set-string buf (rect :x) partial-y (string "       " partial-text) (tui/style)))))

  # Render spinner on last row if active
  (when (spinner-active?)
    (def frame (get spinner-frames (spinner-state :frame)))
    (def msg (spinner-state :message))
    (def y (+ (rect :y) (- height 1)))
    (def spin-text (string " " frame " " msg))
    (tui/buffer-set-string buf (rect :x) y spin-text (colors :separator))))

# ── Widget constructor ─────────────────────────────────────────

(defn create []
  @{:name :chat
    :state @{}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[]

    :handle (fn [self event]
      (def etype (get event :type))
      (cond
        (= etype :submit) (submit (event :text))
        (= etype :stop) (stop)
        (= etype :scroll-up)
        (let [total (length scrollback)
              height (if (self :rect) ((self :rect) :height) 10)
              page-size (max 1 (- height 2))
              max-offset (max 0 (- total height))]
          (set scroll-offset (min max-offset (+ scroll-offset page-size)))
          (widget/mark-dirty :chat))
        (= etype :scroll-down)
        (do
          (def page-size (if (self :rect) (max 1 (- ((self :rect) :height) 2)) 10))
          (set scroll-offset (max 0 (- scroll-offset page-size)))
          (widget/mark-dirty :chat))
        (= etype :scroll-line-up)
        (let [total (length scrollback)
              height (if (self :rect) ((self :rect) :height) 10)
              n (or (get event :lines) 1)
              max-offset (max 0 (- total height))]
          (set scroll-offset (min max-offset (+ scroll-offset n)))
          (widget/mark-dirty :chat))
        (= etype :scroll-line-down)
        (do
          (def n (or (get event :lines) 1))
          (set scroll-offset (max 0 (- scroll-offset n)))
          (widget/mark-dirty :chat))))

    :update (fn [self] (tick))

    :render (fn [self rect buf]
      (render-scrollback rect buf))})
