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
(import core/registers :as reg)
(import tui)
(import tui/markdown :as md)
(import tui/ansi :as ansi)
(import core/profile :as profile)

(var- stream-span-id nil)

# ── Stream provider ───────────────────────────────────────────
# Indirection layer for the LLM backend. Default wraps api/stream-start
# and http/stream-read. Stage mode replaces this with a scriptable queue.

(var- provider
  @{:stream-start (fn [conv tools cbs &opt sys]
                   (api/stream-start conv tools cbs sys))
    :stream-read (fn [stream-id]
                  (http/stream-read stream-id))
    :stream-stop (fn [stream-id]
                  (http/stream-stop stream-id))})

(defn set-provider
  "Replace the stream provider. p must have :stream-start, :stream-read, :stream-stop."
  [p]
  (set provider p))

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
  (reg/list)   # see all register names
  ```

  ### Use registers as working memory

  Registers are a persistent scratchpad across all tool calls in a session. Use them
  to track progress on multi-step tasks — don't rely on the conversation alone.

  **When tackling a task with 3+ steps, write a plan to `:plan` first, then work through it.**

  ```janet
  (import core/registers :as reg)

  # Start of a complex task: write a plan
  (reg/set :plan @["read Cargo.toml" "run failing tests" "find root cause" "fix" "verify"])
  (reg/set :done @[])
  ```

  After each step, pop from `:plan` and push to `:done`:

  ```janet
  (import core/registers :as reg)
  (def plan (reg/get :plan))
  (def done (reg/get :done))
  (array/push done (first plan))
  (reg/set :plan (array/slice plan 1))
  (reg/set :done done)
  # inspect: [(reg/get :done) (reg/get :plan)]
  ```

  Common patterns:
  - **Todo list**: `:plan` / `:done` arrays updated as steps complete
  - **Scratchpad**: stash file contents, grep output, or computed values to reference later
  - **Counters**: track files changed, errors found, tests fixed
  - **Flags**: `(reg/set :config-reviewed false)` at start, flip when done
  - **Intermediate results**: save output of one tool call for use several steps later

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
(var- cached-total-vrows 0)
(var- cached-vrows-width 0)
(var- stream-new-vrows 0)

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

(defn drain-stream-scroll
  "Return and clear the count of new visual rows added during streaming."
  []
  (def n stream-new-vrows)
  (set stream-new-vrows 0)
  n)

(var- thinking-state @{:active false :buf @"" :visible false :char-count 0})
(var- scrollback-dirty true)
(var- prev-y-offset -1)
(var- prev-render-height -1)

# ── Bash progress (live output) ────────────────────────────────
# When a bash command is running and emitting :partial output, we show
# the last N lines in a small live-updating block in the scrollback.
# Lines are tagged {:progress true} so we can find and replace them.

(var- progress-max-lines 5)

(defn reset-state
  "Reset chat state for testing. Clears scrollback, resets mode to idle."
  []
  (array/clear scrollback)
  (set scroll-offset 0)
  (set cached-total-vrows 0)
  (set cached-vrows-width 0)
  (set stream-new-vrows 0)
  (set scrollback-dirty true)
  (set prev-y-offset -1)
  (set prev-render-height -1)
  (set mode :idle)
  (set stream-ctx nil)
  (array/clear steering-queue)
  (array/clear followup-queue)
  (reg/clear :steering)
  (buffer/clear (thinking-state :buf))
  (put thinking-state :active false)
  (put thinking-state :visible false)
  (put thinking-state :char-count 0))

# ── Color scheme (Catppuccin) ─────────────────────────────────
#
# Two built-in themes: :dark (Mocha) and :light (Latte).
# Switch with (chat/set-theme :dark) or (chat/set-theme :light).
# Fine-tune individual keys with (chat/set-colors {...}).

(def themes
  "Built-in color schemes keyed by :dark / :light."
  @{:dark
    # Catppuccin Mocha — Base: 30 30 46
    @{:user-label    (tui/style :fg [:rgb 137 180 250] :bold true)   # Blue
      :agent-label   (tui/style :fg [:rgb 250 179 135] :bold true)   # Peach
      :tool-label    (tui/style :fg [:rgb 166 227 161] :bold true)   # Green
      :error-label   (tui/style :fg [:rgb 243 139 168] :bold true)   # Red
      :separator     (tui/style :fg [:rgb 108 112 134])              # Overlay0
      :eval-linenum  (tui/style :fg [:rgb 127 132 156])              # Overlay1
      :eval-border   (tui/style :fg [:rgb 88 91 112])                # Surface2
      :eval-code     (tui/style :fg [:rgb 205 214 244] :bg [:rgb 49 50 68])  # Text on Surface0
      :tool-bg       (tui/style :fg [:rgb 108 112 134])              # Overlay0
      :diff-red-fg   (tui/style :fg [:rgb 255 160 180] :bg [:rgb 40 20 25])  # Red on darker tinted surface
      :diff-green-fg (tui/style :fg [:rgb 180 255 180] :bg [:rgb 15 40 25])  # Green on darker tinted surface
      :user-row-bg     (tui/style :bg [:rgb 30 34 66])              # Blue-tinted Surface0
      :thinking-label  (tui/style :fg [:rgb 148 148 184] :italic true) # Lavender dimmed
      :agent-row-bg    (tui/style :bg [:rgb 56 40 48])              # Peach-tinted Surface0
      :thinking-row-bg (tui/style :bg [:rgb 40 38 58])              # Lavender-tinted Surface0
      :tool-row-bg     (tui/style :bg [:rgb 34 52 52])              # Green-tinted Surface0
      :tool-success-bg (tui/style :bg [:rgb 15 40 25])              # Darker green
      :tool-error-bg   (tui/style :bg [:rgb 40 20 25])              # Darker red
      :bash-exit-fail  (tui/style :fg [:rgb 243 139 168] :bold true) # Red (same as error-label)
      :bash-prompt     (tui/style :fg [:rgb 166 227 161])            # Green (dimmer than label)
      # Markdown heading/inline styles
      :md-h1         (tui/style :fg [:rgb 205 214 244] :bold true)   # Text – max contrast
      :md-h2         (tui/style :fg [:rgb 180 190 254] :bold true)   # Lavender
      :md-h3         (tui/style :fg [:rgb 148 226 213] :bold true)   # Teal
      :md-h4         (tui/style :fg [:rgb 137 180 250] :bold true)   # Blue
      :md-h5         (tui/style :fg [:rgb 166 173 200])              # Subtext0
      :md-h6         (tui/style :fg [:rgb 147 153 178])              # Overlay2
      :md-code       (tui/style :fg [:rgb 148 226 213] :bg [:rgb 49 50 68]) # Teal on Surface0
      :md-link       (tui/style :fg [:rgb 137 180 250] :underline true) # Blue
      :md-list-marker (tui/style :fg [:rgb 249 226 175])             # Yellow
      :md-code-block (tui/style :fg [:rgb 148 226 213] :bg [:rgb 49 50 68]) # Teal on Surface0
      :reset        (tui/style)}

    :light
    # Catppuccin Latte — Base: 239 241 245
    @{:user-label    (tui/style :fg [:rgb 30 102 245] :bold true)    # Blue
      :agent-label   (tui/style :fg [:rgb 254 100 11] :bold true)   # Peach
      :tool-label    (tui/style :fg [:rgb 64 160 43] :bold true)    # Green
      :error-label   (tui/style :fg [:rgb 210 15 57] :bold true)    # Red
      :separator     (tui/style :fg [:rgb 156 160 176])             # Overlay0
      :eval-linenum  (tui/style :fg [:rgb 140 143 161])             # Overlay1
      :eval-border   (tui/style :fg [:rgb 172 176 190])             # Surface2
      :eval-code     (tui/style :fg [:rgb 76 79 105] :bg [:rgb 204 208 218])  # Text on Surface0
      :tool-bg       (tui/style :fg [:rgb 156 160 176])             # Overlay0
      :diff-red-fg   (tui/style :fg [:rgb 210 15 57] :bg [:rgb 245 218 222])  # Red on pink-tinted
      :diff-green-fg (tui/style :fg [:rgb 64 160 43] :bg [:rgb 218 240 218])  # Green on green-tinted
      :user-row-bg     (tui/style :bg [:rgb 220 225 248])           # Blue-tinted Mantle
      :thinking-label  (tui/style :fg [:rgb 114 110 140] :italic true) # Lavender dimmed
      :agent-row-bg    (tui/style :bg [:rgb 244 228 218])           # Peach-tinted Mantle
      :thinking-row-bg (tui/style :bg [:rgb 228 226 242])           # Lavender-tinted Mantle
      :tool-row-bg     (tui/style :bg [:rgb 222 238 224])           # Green-tinted Mantle
      :tool-success-bg (tui/style :bg [:rgb 218 240 222])           # Deeper green
      :tool-error-bg   (tui/style :bg [:rgb 246 218 224])           # Deeper red
      :bash-exit-fail  (tui/style :fg [:rgb 210 15 57] :bold true)   # Red (same as error-label)
      :bash-prompt     (tui/style :fg [:rgb 64 160 43])              # Green (dimmer than label)
      # Markdown heading/inline styles
      :md-h1         (tui/style :fg [:rgb 76 79 105] :bold true)    # Text – max contrast
      :md-h2         (tui/style :fg [:rgb 114 105 189] :bold true)  # Lavender
      :md-h3         (tui/style :fg [:rgb 23 146 153] :bold true)   # Teal
      :md-h4         (tui/style :fg [:rgb 30 102 245] :bold true)   # Blue
      :md-h5         (tui/style :fg [:rgb 108 111 133])             # Subtext0
      :md-h6         (tui/style :fg [:rgb 124 127 147])             # Overlay2
      :md-code       (tui/style :fg [:rgb 23 146 153] :bg [:rgb 204 208 218]) # Teal on Surface0
      :md-link       (tui/style :fg [:rgb 30 102 245] :underline true) # Blue
      :md-list-marker (tui/style :fg [:rgb 223 142 29])             # Yellow
      :md-code-block (tui/style :fg [:rgb 23 146 153] :bg [:rgb 204 208 218]) # Teal on Surface0
      :reset        (tui/style)}})

(def- colors
  "Active color scheme. Starts as a copy of the dark theme."
  (table/clone (themes :dark)))

(defn- sync-md-styles
  "Push the :md-* keys from the active color scheme to tui/markdown."
  [theme]
  (def md-overrides @{})
  (eachp [k v] theme
    (when (string/has-prefix? "md-" (string k))
      (def short-key (keyword (string/slice (string k) 3)))
      (put md-overrides short-key v)))
  (when (next md-overrides)
    (md/set-md-styles md-overrides)))

(defn set-theme
  "Apply a built-in theme (:dark or :light). Call from ~/.gent/init.janet."
  [name]
  (def theme (get themes name))
  (when (nil? theme) (error (string "unknown theme: " name)))
  (eachp [k _] colors (put colors k nil))
  (eachp [k v] theme (put colors k v))
  (sync-md-styles theme))

(defn set-colors
  "Override individual color entries on top of the current theme."
  [overrides]
  (eachp [k v] overrides
    (put colors k v)))

(defn detect-os-theme
  "Detect the OS appearance. Returns :dark or :light.
   On macOS, reads AppleInterfaceStyle. Defaults to :dark on other platforms."
  []
  (try
    (let [result (process/exec "defaults" ["read" "-g" "AppleInterfaceStyle"])]
      (if (and (= 0 (result :status))
               (string/has-prefix? "Dark" (string/trim (result :stdout))))
        :dark
        :light))
    ([_] :dark)))

(defn auto-theme
  "Detect the OS appearance and apply the matching theme."
  []
  (set-theme (detect-os-theme)))

# ── Visual row expansion ──────────────────────────────────────
# These must be defined before push-line (which uses count-visual-rows).

(defn- line-to-visual-rows
  "Convert a scrollback line into an array of visual rows.
   Each visual row is an array of {:text :style} spans that fit within width.
   Lines that exceed width wrap at word boundaries (spaces) when possible,
   falling back to hard character breaks for long words.
   Continuation rows are indented by :wrap-indent spaces (auto-detected from
   the first span of span-based lines)."
  [line width]

  (def rows @[])
  (var current-row @[])
  (var col 0)
  (def wrap-indent (or (get line :wrap-indent) 0))

  (defn- flush-row []
    (when (> (length current-row) 0)
      (array/push rows (array/slice current-row))
      (array/clear current-row)
      (set col 0)))

  (defn- pad-continuation []
    (when (and (> wrap-indent 0) (> (length rows) 0))
      (for _ 0 wrap-indent
        (array/push current-row @{:text " " :style (tui/style)}))
      (set col wrap-indent)))

  (defn- word-wrap-flush []
    # Look back for the last space in current-row to break at a word boundary
    (var break-idx nil)
    # Don't search into the indent padding on continuation rows
    (def search-start (if (> (length rows) 0) wrap-indent 0))
    (for i 0 (length current-row)
      (def pos (- (length current-row) 1 i))
      (when (< pos search-start) (break))
      (when (= ((get current-row pos) :text) " ")
        (set break-idx pos)
        (break)))
    (if (and break-idx (> break-idx 0))
      (do
        # Split: everything up to and including the space goes on this row,
        # everything after wraps to the next row
        (def keep (array/slice current-row 0 (+ break-idx 1)))
        (def overflow (array/slice current-row (+ break-idx 1)))
        (array/push rows keep)
        (array/clear current-row)
        (set col 0)
        (pad-continuation)
        (array/concat current-row overflow)
        (var overflow-width 0)
        (each s overflow
          (+= overflow-width (tui/char-width (s :text))))
        (set col (+ col overflow-width)))
      # No space found — hard break at width
      (do
        (flush-row)
        (pad-continuation))))

  (defn- add-text-chars [text style]
    (var ci 0)
    (while (< ci (length text))
      (def byte (get text ci))
      # Handle newlines explicitly - they should force a row break
      (if (= byte (chr "\n"))
        (do
          (flush-row)
          (++ ci))
        (do
          (def char-len
            (cond (< byte 0x80) 1 (< byte 0xE0) 2 (< byte 0xF0) 3 4))
          (def cend (min (+ ci char-len) (length text)))
          (def ch (string/slice text ci cend))
          (def w (tui/char-width ch))
          (if (= w 0)
            # Zero-width char (combining mark, variation selector, ZWJ, etc.)
            # Append to the previous cell's text so the terminal renders them
            # together with the base character.
            (when (> (length current-row) 0)
              (def prev (last current-row))
              (put prev :text (string (prev :text) ch)))
            (do
              (when (> (+ col w) width)
                (word-wrap-flush))
              (array/push current-row @{:text ch :style style})
              (+= col w)))
          (set ci cend)))))

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

(defn- line-to-visual-rows-cached
  "Like line-to-visual-rows but caches results on the scrollback entry.
   Cache hit when width matches :_cached-width."
  [line width]
  (if (and (= (get line :_cached-width) width) (get line :_cached-rows))
    (line :_cached-rows)
    (do
      (def rows (line-to-visual-rows line width))
      (when (table? line)
        (put line :_cached-width width)
        (put line :_cached-rows rows))
      rows)))

(defn- count-visual-rows
  "Count how many visual rows a scrollback line occupies at given width."
  [line width]
  (length (line-to-visual-rows-cached line width)))

(defn- effective-width
  "Return the content width for a scrollback line.
   Lines with a :row-style get a gutter column, so their content is 1 char narrower."
  [line width]
  (if (line :row-style) (- width 1) width))

(defn- get-chat-content-width []
  "Return the available width for table content inside the chat widget.
   Uses the inner content rect (after borders) when available, otherwise
   falls back to the widget rect minus 2 for the standard chat border.
   Subtracts gutter (1) and prefix (9) since agent tables appear after
   the '   gent: ' prefix."
  (def w (widget/get-widget :chat))
  (def cr (if w (w :content-rect) nil))
  (def raw
    (if (and cr (cr :width))
      (cr :width)
      (if (and w (w :rect))
        # Approximate: outer rect minus 2 for the standard chat border
        (- ((w :rect) :width) 2)
        80)))
  # Agent lines have :row-style (gutter=1) + prefix '         ' (9 cols)
  (- raw 10))

(defn- total-visual-rows
  "Cached total visual rows. Recomputes on width change."
  [width]
  (if (= cached-vrows-width width)
    cached-total-vrows
    (do
      (var total 0)
      (each line scrollback
        (set total (+ total (count-visual-rows line (effective-width line width)))))
      (set cached-total-vrows total)
      (set cached-vrows-width width)
      total)))

# ── Output helpers (scrollback-based) ─────────────────────────

(defn- push-line
  "Add a styled line to the scrollback. Marks widget dirty.
   When scrolled up (offset > 0), increments offset by the visual row
   count of the new line so the visible window stays pinned.
   Optional wrap-indent sets the indentation for continuation rows when wrapping."
  [text &opt style wrap-indent]
  (default style (tui/style))
  (def new-line @{:text text :style style})
  (when wrap-indent (put new-line :wrap-indent wrap-indent))
  (array/push scrollback new-line)
  (set scrollback-dirty true)
  (when (> cached-vrows-width 0)
    (def ew (effective-width new-line cached-vrows-width))
    (set cached-total-vrows (+ cached-total-vrows (count-visual-rows new-line ew))))
  (when (> scroll-offset 0)
    (def w (widget/get-widget :chat))
    (def width (if (and w (w :rect)) ((w :rect) :width) 80))
    (set scroll-offset (+ scroll-offset (count-visual-rows new-line width))))
  (when (> (length scrollback) max-scrollback)
    (when (> cached-vrows-width 0)
      (def old-line (get scrollback 0))
      (def ew (effective-width old-line cached-vrows-width))
      (set cached-total-vrows (- cached-total-vrows (count-visual-rows old-line ew))))
    (array/remove scrollback 0 (- (length scrollback) max-scrollback)))
  (widget/mark-dirty :chat))

(defn- push-raw-line
  "Add a pre-formatted line (array of spans) to the scrollback.
   When scrolled up, increments offset by visual row count to keep the view stable.
   Auto-detects :wrap-indent from the first span's text length when there are
   multiple spans (the first span is typically a label like '   gent: ')."
  [spans]
  (def new-line @{:spans spans})
  # Auto-detect wrap indent: first span of multi-span lines is the label prefix
  (when (and (> (length spans) 1) (get (first spans) :text))
    (put new-line :wrap-indent (tui/string-width ((first spans) :text))))
  (array/push scrollback new-line)
  (set scrollback-dirty true)
  (when (> cached-vrows-width 0)
    (def ew (effective-width new-line cached-vrows-width))
    (def nvr (count-visual-rows new-line ew))
    (set cached-total-vrows (+ cached-total-vrows nvr))
    (when (= scroll-offset 0)
      (set stream-new-vrows (+ stream-new-vrows nvr))))
  (when (> scroll-offset 0)
    (def w (widget/get-widget :chat))
    (def width (if (and w (w :rect)) ((w :rect) :width) 80))
    (set scroll-offset (+ scroll-offset (count-visual-rows new-line width))))
  (when (> (length scrollback) max-scrollback)
    (when (> cached-vrows-width 0)
      (def old-line (get scrollback 0))
      (def ew (effective-width old-line cached-vrows-width))
      (set cached-total-vrows (- cached-total-vrows (count-visual-rows old-line ew))))
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

(defn- has-ansi?
  "Check if a string contains ANSI escape sequences."
  [text]
  (truthy? (string/find "\x1b[" text)))

(defn- push-ansi-line
  "Push a line that may contain ANSI escape codes.
   If ANSI codes are found, parses them into styled spans and uses push-raw-line.
   Otherwise falls back to push-line with the given style.
   The prefix is prepended to the line text before parsing."
  [text base-style wrap-indent]
  (if (has-ansi? text)
    (do
      (def spans (ansi/ansi->spans text base-style))
      # Filter out empty spans
      (def filtered (filter |(not= "" ($ :text)) spans))
      (if (> (length filtered) 0)
        (do
          (def line @{:spans (array ;filtered) :wrap-indent wrap-indent})
          (push-raw-line (line :spans))
          (put (last scrollback) :wrap-indent wrap-indent))
        (push-line text base-style wrap-indent)))
    (push-line text base-style wrap-indent)))

# ── Formatted output ──────────────────────────────────────────

(defn output
  "Add a plain line to scrollback."
  [text]
  (push-line text))

(defn output-info [text]
  (push-line text (colors :separator)))

(defn output-error [text]
  (push-raw-line
    @[@{:text "   err:  " :style (colors :error-label)}
      @{:text text :style (tui/style)}]))

(defn output-user [text]
  (when (> (length scrollback) 0) (push-line ""))  # Single blank line
  (def lines (string/split "\n" text))
  (var first true)
  (each line lines
    (def prefix
      (if first
        (do (set first false)
            @{:text "   user: " :style (colors :user-label)})
        @{:text "         " :style (tui/style)}))
    (push-raw-line
      @[prefix @{:text line :style (tui/style)}])
    (put (last scrollback) :row-style :user-row-bg)))

(defn output-agent [lines]
  "Add agent response to scrollback with markdown styling."
  (when (> (length scrollback) 0) (push-line ""))
  (var first true)
  (def max-w (get-chat-content-width))
  (def parser
    (md/create-chat-markdown-parser
      (fn [spans]
        (def prefixed
          (if first
            (do (set first false)
                (array/concat @[@{:text "   gent: " :style (colors :agent-label)}] spans))
            (array/concat @[@{:text "         " :style (tui/style)}] spans)))
        (push-raw-line prefixed)
        (put (last scrollback) :row-style :agent-row-bg))
      max-w))
  ((parser :feed) lines)
  ((parser :finish))
  (push-line ""))

(defn output-skills [skill-list]
  "Render a formatted skills listing into the scrollback."
  (def sorted (sort-by |($ :name) skill-list))
  (push-line (string "  " (length sorted) " skills:") (tui/style) 2)
  (push-line "")
  (each s sorted
    (push-raw-line
      @[@{:text "         " :style (tui/style)}
        @{:text (s :name) :style (tui/style :bold true)}
        @{:text (string " — " (s :description)) :style (tui/style)}])))

(defn output-tool [name &opt detail]
  (push-raw-line
    @[@{:text (string "   ▸ " name) :style (colors :tool-label)}
      @{:text (if detail (string " " detail) "") :style (colors :separator)}])
  (put (last scrollback) :row-style :tool-row-bg))

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
      @[@{:text (string "         " linenum " ") :style (colors :eval-linenum)}
        @{:text "│" :style (colors :eval-border)}
        @{:text (string " " code-line) :style (colors :eval-code)}])
    (put (last scrollback) :row-style :tool-row-bg)))

(defn output-edit-file [input]
  "Render edit_file with diff display."
  (def path (get input :path ""))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))
  (def is-create (= "" old-str))
  (def max-diff-lines 8)

  (if is-create
    (push-raw-line
      @[@{:text "   ▸ edit_file" :style (colors :tool-label)}
        @{:text (string " " path " ") :style (colors :separator)}
        @{:text "(new file)" :style (colors :tool-label)}])
    (push-raw-line
      @[@{:text "   ▸ edit_file" :style (colors :tool-label)}
        @{:text (string " " path) :style (colors :separator)}]))
  (put (last scrollback) :row-style :tool-row-bg)

  (when (not= "" old-str)
    (def old-lines (string/split "\n" old-str))
    (def show-n (min (length old-lines) max-diff-lines))
    (for i 0 show-n
      (push-line (string "         - " (get old-lines i "")) (colors :diff-red-fg) 9)
      (put (last scrollback) :row-style :tool-row-bg))
    (when (> (length old-lines) max-diff-lines)
      (push-line (string "         … " (- (length old-lines) max-diff-lines) " more lines") (colors :separator) 9)
      (put (last scrollback) :row-style :tool-row-bg)))

  (when (not= "" new-str)
    (def new-lines (string/split "\n" new-str))
    (def show-n (min (length new-lines) max-diff-lines))
    (for i 0 show-n
      (push-line (string "         + " (get new-lines i "")) (colors :diff-green-fg) 9)
      (put (last scrollback) :row-style :tool-success-bg))
    (when (> (length new-lines) max-diff-lines)
      (push-line (string "         … " (- (length new-lines) max-diff-lines) " more lines") (colors :separator) 9)
      (put (last scrollback) :row-style :tool-success-bg))))

(var- tool-result-max-lines 10)

(defn set-tool-result-max-lines [n]
  (set tool-result-max-lines n))

(defn output-tool-result [text &opt success]
  (default success true)
  (def row-bg (if success :tool-success-bg :tool-error-bg))
  (def lines (string/split "\n" text))
  (def total (length lines))
  (def show-lines (min total tool-result-max-lines))
  (for i 0 show-lines
    (def line (get lines i ""))
    (def line-text (string "         " line))
    (push-ansi-line line-text (colors :separator) 9)
    (put (last scrollback) :row-style row-bg))
  (when (> total tool-result-max-lines)
    (push-line (string "         … " (- total tool-result-max-lines) " more lines omitted") (colors :separator) 9)
    (put (last scrollback) :row-style row-bg)))

# ── Pluggable tool renderers ──────────────────────────────────

(var- tool-renderers @{})
(var- tool-result-renderers @{})

(defn set-tool-renderer [name renderer]
  (if renderer (put tool-renderers name renderer)
    (put tool-renderers name nil)))

(defn set-tool-result-renderer [name renderer]
  (if renderer (put tool-result-renderers name renderer)
    (put tool-result-renderers name nil)))

# ── Human-readable tool-call headers ─────────────────────────

(defn output-read-file [input]
  (def path (get input :path ""))
  (output-tool "Read" path))

(defn output-bash [input]
  (def cmd (get input :command ""))
  (push-raw-line
    @[@{:text "   ▸ Bash" :style (colors :tool-label)}
      @{:text "  $ " :style (colors :bash-prompt)}
      @{:text cmd :style (colors :separator)}])
  (put (last scrollback) :row-style :tool-row-bg))

(defn output-list-files [input]
  (def path (or (get input :path) "."))
  (output-tool "List" path))

(defn output-use-skill [input]
  (def skill-name (get input :name ""))
  (output-tool "Skill" skill-name))

(defn output-prompt-user [input]
  (def title (get input :title ""))
  (output-tool "Ask" title))

# ── Human-readable tool-result renderers ─────────────────────

(defn output-bash-result [text]
  "Parse bash result and render structured output.
   Handles both structured format (exit code: N\\nstdout:\\n...\\nstderr:\\n...)
   and raw format (plain output, optionally ending with 'Command exited with code N')."
  (def lines (string/split "\n" text))
  (var exit-code 0)
  (var section nil)
  (def stdout-lines @[])
  (def stderr-lines @[])
  (def raw-lines @[])
  (var has-structured-format false)

  (each line lines
    (cond
      (string/has-prefix? "exit code: " line)
      (do (set exit-code (or (scan-number (string/slice line 11)) 0))
          (set has-structured-format true))

      (= "stdout:" line) (do (set section :stdout) (set has-structured-format true))
      (= "stderr:" line) (do (set section :stderr) (set has-structured-format true))

      (= section :stdout) (array/push stdout-lines line)
      (= section :stderr) (array/push stderr-lines line)

      # Raw format: collect all lines
      (array/push raw-lines line)))

  # Detect exit code from raw format (e.g. "Command exited with code 1")
  (when (and (not has-structured-format) (> (length raw-lines) 0))
    (def last-line (last raw-lines))
    (when (string/has-prefix? "\nCommand exited with code " (string "\n" last-line))
      (def code-str (string/slice last-line (length "Command exited with code ")))
      (set exit-code (or (scan-number code-str) 0))
      (array/pop raw-lines)
      # Also remove the preceding empty line if present
      (when (and (> (length raw-lines) 0) (= "" (last raw-lines)))
        (array/pop raw-lines))))

  # Choose which lines to display
  (def all-lines
    (if has-structured-format
      (do
        # Trim trailing empty lines from structured format
        (while (and (> (length stdout-lines) 0) (= "" (last stdout-lines)))
          (array/pop stdout-lines))
        (while (and (> (length stderr-lines) 0) (= "" (last stderr-lines)))
          (array/pop stderr-lines))
        (array/concat @[] stdout-lines stderr-lines))
      (do
        # Trim trailing empty lines from raw format
        (while (and (> (length raw-lines) 0) (= "" (last raw-lines)))
          (array/pop raw-lines))
        raw-lines)))

  (def success (= 0 exit-code))
  (def row-bg (if success :tool-success-bg :tool-error-bg))

  # Show exit code only on failure
  (when (not success)
    (push-raw-line
      @[@{:text (string "         ✗ exit " exit-code) :style (colors :bash-exit-fail)}])
    (put (last scrollback) :row-style row-bg))

  # Show output lines
  (def total (length all-lines))
  (def show-n (min total tool-result-max-lines))
  (for i 0 show-n
    (def line-text (string "         " (get all-lines i "")))
    (push-ansi-line line-text (colors :separator) 9)
    (put (last scrollback) :row-style row-bg))
  (when (> total tool-result-max-lines)
    (push-line (string "         … " (- total tool-result-max-lines) " more lines omitted") (colors :separator) 9)
    (put (last scrollback) :row-style row-bg)))

(defn output-read-file-result [result]
  "Render read_file result with line numbers."
  (def text (if (or (table? result) (array? result) (tuple? result))
              (break (output-tool-result
                       (string "[Image: " (get-in result [:source :media_type] "unknown") "]")))
              (string result)))
  (def is-error (and (string? text) (string/has-prefix? "Error" text)))
  (when is-error
    (break (output-tool-result text false)))
  (def lines (string/split "\n" text))
  (def total (length lines))
  (def show-n (min total tool-result-max-lines))
  (def num-width (max 2 (length (string total))))
  (for i 0 show-n
    (def linenum (string/format (string "%" num-width "d") (+ i 1)))
    (def code-line (get lines i ""))
    (push-raw-line
      @[@{:text (string "         " linenum " ") :style (colors :eval-linenum)}
        @{:text "│" :style (colors :eval-border)}
        @{:text (string " " code-line) :style (colors :separator)}])
    (put (last scrollback) :row-style :tool-success-bg))
  (when (> total tool-result-max-lines)
    (push-line (string "         … " (- total tool-result-max-lines) " more lines") (colors :separator) 9)
    (put (last scrollback) :row-style :tool-success-bg)))

# ── Live bash progress ─────────────────────────────────────────

(defn- remove-progress-lines
  "Remove all scrollback lines tagged {:progress true}."
  []
  (var i (- (length scrollback) 1))
  (var removed 0)
  (while (>= i 0)
    (when (get (get scrollback i) :progress)
      (when (> cached-vrows-width 0)
        (def line (get scrollback i))
        (def ew (effective-width line cached-vrows-width))
        (set cached-total-vrows (- cached-total-vrows (count-visual-rows line ew))))
      (array/remove scrollback i)
      (++ removed))
    (-- i))
  (when (> removed 0)
    (set scrollback-dirty true)
    (widget/mark-dirty :chat))
  removed)

(defn- push-progress-line
  "Add a progress line to the scrollback (tagged for later removal).
   Supports both plain text (with a style) and ANSI-styled spans."
  [text style]
  (def new-line
    (if (has-ansi? text)
      (do
        (def spans (ansi/ansi->spans text style))
        (def filtered (filter |(not= "" ($ :text)) spans))
        (if (> (length filtered) 0)
          @{:spans (array ;filtered) :progress true :row-style :tool-row-bg :wrap-indent 9}
          @{:text text :style style :progress true :row-style :tool-row-bg}))
      @{:text text :style style :progress true :row-style :tool-row-bg}))
  (array/push scrollback new-line)
  (set scrollback-dirty true)
  (when (> cached-vrows-width 0)
    (def ew (effective-width new-line cached-vrows-width))
    (set cached-total-vrows (+ cached-total-vrows (count-visual-rows new-line ew))))
  (widget/mark-dirty :chat))

(defn update-bash-progress
  "Show the last N lines of partial bash output as a live progress block."
  [partial-output]
  (remove-progress-lines)
  (def all-lines (string/split "\n" partial-output))
  # Remove trailing empty lines
  (while (and (> (length all-lines) 0) (= "" (last all-lines)))
    (array/pop all-lines))
  (def total (length all-lines))
  (when (= total 0) (break))
  (def show-start (max 0 (- total progress-max-lines)))
  (def sep-style (colors :separator))
  # Header line showing progress
  (def header
    (if (> total progress-max-lines)
      (string "         ┄ " total " lines (" (- total progress-max-lines) " hidden) ┄")
      (string "         ┄ output ┄")))
  (push-progress-line header sep-style)
  (for i show-start total
    (push-progress-line (string "         " (get all-lines i "")) sep-style)))

(defn render-tool-call [name input]
  (when (> (length scrollback) 0) (push-line ""))
  (def custom (get tool-renderers name))
  (if custom
    (custom input)
    (cond
      (= "eval_janet" name) (output-eval-janet (get input :code ""))
      (= "edit_file" name) (output-edit-file input)
      (= "read_file" name) (output-read-file input)
      (= "bash" name) (output-bash input)
      (= "list_files" name) (output-list-files input)
      (= "use_skill" name) (output-use-skill input)
      (= "prompt_user" name) (output-prompt-user input)
      (output-tool name (json/encode input)))))

(defn render-tool-result [name result]
  (def custom (get tool-result-renderers name))
  (if custom
    (custom result)
    (cond
      (= "bash" name) (output-bash-result (string result))
      (= "read_file" name) (output-read-file-result result)
      # edit_file: the diff display already shows what happened; suppress "OK"
      (and (= "edit_file" name) (= "OK" (string result))) nil
      (do
        (def text (if (or (table? result) (array? result) (tuple? result))
                    (string "[Image: " (get-in result [:source :media_type] "unknown") "]")
                    (string result)))
        (def is-error (and (string? text)
                           (string/has-prefix? "Error" text)))
        (output-tool-result text (not is-error))))))

(defn output-eval [code result]
  "Display an inline Janet eval."
  (push-raw-line
    @[@{:text "   eval: " :style (colors :tool-label)}
      @{:text code :style (colors :separator)}])
  (when (and result (not= "" result))
    (each line (string/split "\n" result)
      (push-raw-line
        @[@{:text "      => " :style (colors :tool-label)}
          @{:text line :style (tui/style)}]))))

# ── Streaming output ──────────────────────────────────────────

(var- stream-state @{:active false :line-buf @"" :first true :parser nil})

(defn- stream-start-output []
  (when (> (length scrollback) 0) (push-line ""))
  (put stream-state :active true)
  (put stream-state :first true)
  (buffer/clear (stream-state :line-buf))
  (def max-w (get-chat-content-width))
  (def parser
    (md/create-chat-markdown-parser
      (fn [spans]
        (def prefixed
          (if (stream-state :first)
            (do (put stream-state :first false)
                (array/concat @[@{:text "   gent: " :style (colors :agent-label)}] spans))
            (array/concat @[@{:text "         " :style (tui/style)}] spans)))
        (push-raw-line prefixed)
        (put (last scrollback) :row-style :agent-row-bg))
      max-w))
  (put stream-state :parser parser))

(defn- stream-delta [text]
  (def parser (stream-state :parser))
  ((parser :feed) text)
  (def buf (stream-state :line-buf))
  (each byte text
    (if (= byte (chr "\n"))
      (buffer/clear buf)
      (buffer/push buf byte)))
  (widget/mark-dirty :chat))

(defn- stream-end-output []
  (def parser (stream-state :parser))
  (when parser ((parser :finish)))
  (def had-content (not (stream-state :first)))
  (buffer/clear (stream-state :line-buf))
  (put stream-state :active false)
  (put stream-state :first true)
  (put stream-state :parser nil)
  (when had-content (push-line "")))

# ── Spinner ────────────────────────────────────────────────────
# Spinner renders as a 3-row gentleman with top hat, monocle, and occasional smile.

(def- spinner-height 1)
(def- spinner-gent-width 5)
(def- spinner-frames
  [" ◔_• " " ◑_• " " ◕_• " " ●‿• "
   " ◕_• " " ◑_• " " ◔_• " " ◑‿• "
   " ◕_• " " ●‿• " " ◕‿• " " ◑_• "])
(def- spinner-interval 167)
(var- spinner-state @{:active false :frame 0 :message "" :last-tick 0})

(defn get-spinner-state
  "Return the spinner state table (for testing)."
  [] spinner-state)

(defn- spinner-start [msg]
  (put spinner-state :active true)
  (put spinner-state :frame 0)
  (put spinner-state :message msg)
  (put spinner-state :last-tick (os/clock))
  (widget/mark-dirty :chat))

(defn- spinner-active? [] (spinner-state :active))

(defn- spinner-tick []
  (when (spinner-state :active)
    (def now (os/clock))
    (def elapsed (* (- now (spinner-state :last-tick)) 1000))
    (when (>= elapsed spinner-interval)
      (put spinner-state :last-tick now)
      (put spinner-state :frame (% (+ (spinner-state :frame) 1) (length spinner-frames)))
      (widget/mark-dirty :chat))))

(defn- spinner-stop []
  (when (spinner-state :active)
    (put spinner-state :active false)
    (widget/mark-dirty :chat)))

# ── Thinking display ──────────────────────────────────────────

(defn- format-char-count [n]
  (if (>= n 1000)
    (string/format "%.1fk" (/ n 1000))
    (string n)))

(defn- thinking-delta [text]
  (put thinking-state :active true)
  (buffer/push (thinking-state :buf) text)
  (put thinking-state :char-count (+ (thinking-state :char-count) (length text)))
  (if (thinking-state :visible)
    (do
      (def w (widget/get-widget :chat))
      (def max-width
        (if (and w (w :rect))
          (max 20 (- ((w :rect) :width) 10))
          72))
      (each byte text
        (if (= byte (chr "\n"))
          (do
            (def line (string (thinking-state :buf)))
            (buffer/clear (thinking-state :buf))
            (if (= "" line)
              (do (push-line "")
                  (put (last scrollback) :row-style :thinking-row-bg))
              (do
                (def wrapped (word-wrap line max-width))
                (each wl wrapped
                  (push-line (string "         " wl) nil 9)
                  (put (last scrollback) :row-style :thinking-row-bg)))))
          nil))
      (widget/mark-dirty :chat))
    (do
      (def msg (string "thinking (" (format-char-count (thinking-state :char-count)) " chars)…"))
      (if (spinner-active?)
        # Update message without resetting frame/tick — prevents static spinner
        # when thinking deltas arrive faster than the animation interval
        (do
          (put spinner-state :message msg)
          (widget/mark-dirty :chat))
        (spinner-start msg)))))

(defn- thinking-end-block []
  "Push the buffered thinking content as a collapsed block in scrollback."
  (when (thinking-state :active)
    (def content (string (thinking-state :buf)))
    (def char-count (thinking-state :char-count))
    (when (> char-count 0)
      (if (thinking-state :visible)
        (push-line "")
        (do
          (def summary (string "   think: (" (format-char-count char-count) " chars) — ctrl+t to expand"))
          (push-raw-line
            @[@{:text summary :style (colors :thinking-label)}])
          (put (last scrollback) :row-style :thinking-row-bg)
          (put (last scrollback) :thinking-content content))))
    (buffer/clear (thinking-state :buf))
    (put thinking-state :active false)
    (put thinking-state :char-count 0)))

(defn toggle-thinking-visibility []
  "Toggle between showing/hiding thinking content."
  (put thinking-state :visible (not (thinking-state :visible)))
  (def visible (thinking-state :visible))
  (def w (widget/get-widget :chat))
  (def max-width
    (if (and w (w :rect))
      (max 20 (- ((w :rect) :width) 10))
      72))
  (var i 0)
  (while (< i (length scrollback))
    (def line (get scrollback i))
    (def content (get line :thinking-content))
    (when (and content (not= "" content))
      (if visible
        (do
          (put line :spans nil)
          (put line :text nil)
          (put line :_cached-width nil)
          (put line :_cached-rows nil)
          (def parts (string/split "\n" content))
          (def expanded @[])
          (var first-part true)
          (each part parts
            (if (= "" part)
              (array/push expanded @{:text "" :style (tui/style) :row-style :thinking-row-bg})
              (do
                (def wrapped (word-wrap part max-width))
                (each wl wrapped
                  (if first-part
                    (do
                      (array/push expanded
                        @{:spans @[@{:text "   think: " :style (colors :thinking-label)}
                                   @{:text wl :style (colors :thinking-label)}]
                          :row-style :thinking-row-bg})
                      (set first-part false))
                    (array/push expanded
                      @{:text (string "          " wl) :style (colors :thinking-label)
                        :row-style :thinking-row-bg}))))))
          (when (> (length expanded) 0)
            (def first-expanded (get expanded 0))
            (eachp [k v] first-expanded (put line k v))
            (put line :thinking-content content)
            (put line :_cached-width nil)
            (put line :_cached-rows nil)
            (for j 1 (length expanded)
              (def exp-line (get expanded j))
              (put exp-line :thinking-content "")
              (array/insert scrollback (+ i j) exp-line))
            (set i (+ i (length expanded)))))
        (do
          (var end (+ i 1))
          (while (and (< end (length scrollback))
                      (not (nil? (get-in scrollback [end :thinking-content]))))
            (++ end))
          (when (> (- end i) 1)
            (array/remove scrollback (+ i 1) (- end i 1)))
          (def summary (string "   think: (" (format-char-count (length content)) " chars) — ctrl+t to expand"))
          (put line :spans @[@{:text summary :style (colors :thinking-label)}])
          (put line :text nil)
          (put line :row-style :thinking-row-bg)
          (put line :_cached-width nil)
          (put line :_cached-rows nil))))
    (++ i))
  (widget/mark-dirty :chat)
  visible)

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
  (set stream-span-id (profile/begin "stream:api-call" "stream"))
  (def ctx
    ((provider :stream-start)
     conversation
     (tools/definitions)
     @{:on-text (fn [text]
                 (when (thinking-state :active) (thinking-end-block))
                 (when (spinner-active?) (spinner-stop))
                 (stream-delta text))
       :on-thinking (fn [text]
                     (thinking-delta text))
       :on-tool-start (fn [name]
                       (stream-end-output)
                       (spinner-start (string "streaming " name " arguments…")))
       :on-tool-delta (fn [name nbytes]
                       (def size-str
                         (if (>= nbytes 1024)
                           (string/format "%.1fKB" (/ nbytes 1024))
                           (string nbytes "B")))
                       (put spinner-state :message (string "streaming " name " arguments… (" size-str ")")))
       :on-error (fn [err]
                  (spinner-stop)
                  (output-error (string "Stream error: " err))
                  (hooks/run :on-error err))}
      effective-prompt))
  (set stream-ctx ctx)
  (set mode :streaming))

(defn- drain-stream []
  (profile/with-span "stream:drain" "stream" (fn []
                                              (def parser (stream-ctx :parser))
                                              (def stream-id (get stream-ctx :stream-id))
                                              (var result nil)
                                              (var keep-going true)
                                              (var budget 32)
                                              (while (and keep-going (> budget 0))
                                                (-- budget)
                                                (def line ((provider :stream-read) stream-id))
                                                (cond
                                                  (nil? line) (set keep-going false)
                                                  (= :done line) (do (set result :done) (set keep-going false))
                                                  (and (table? line) (= :error (get line :type)))
                                                  (do (output-error (string "Stream error: " (get line :message "unknown")))
                                                      (set result :error) (set keep-going false))
                                                  (string? line) ((parser :feed) line)))
                                              result)))

# ── Tool execution ─────────────────────────────────────────────

(var- start-next-tool nil)

(defn- finish-current-async-tool [result]
  (def idx (tool-exec :current-idx))
  (def tc (get (tool-exec :tool-calls) idx))
  (hooks/run :after-tool-call (tc :name) (tc :input) result)
  # Remove live progress lines before rendering the final result
  (remove-progress-lines)
  (spinner-stop)
  (def result-hook-handled (hooks/run :render-tool-result (tc :name) result))
  (unless result-hook-handled (render-tool-result (tc :name) result))
  (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
  (put tool-exec :async-handle nil)
  (put tool-exec :current-idx (+ idx 1))
  (start-next-tool))

(defn- enter-idle []
  (hooks/run :turn-end)
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
  # Drain the :steering register inbox into the local queue so that
  # external callers (other agents, RPC, eval_janet) can steer by pushing
  # to (reg/push :steering "message").
  (each msg (reg/drain :steering)
    (array/push steering-queue msg))
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
    (def idx (tool-exec :current-idx))
    (when (abort/aborted?)
      (remove-progress-lines)
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
        # All tools go through the async path. Dispatch is deferred to the
        # first poll so the event loop can render the spinner before execution.
        # Phase: :pending → :dispatching → :delegating (for native async tools)
        (var phase :pending)
        (var inner-handle nil)
        (put tool-exec :async-handle
          (tools/async-tool
            (fn []
              (case phase
                # First poll: yield nil so the spinner gets at least one tick
                :pending (do (set phase :dispatching) nil)
                # Second poll: actually dispatch the tool
                :dispatching
                (do
                  (def result (tools/dispatch name input))
                  (if (tools/async? result)
                    # Tool is natively async (bash, prompt_user) — delegate
                    (do (set inner-handle result)
                        (set phase :delegating)
                        ((inner-handle :poll)))
                    # Sync tool finished — return result
                    [:done result]))
                # Subsequent polls: delegate to the native async handle
                :delegating
                (when inner-handle ((inner-handle :poll)))))
            (fn []
              (when inner-handle
                ((inner-handle :cancel))))))))))

(defn- handle-stream-done []
  (profile/end stream-span-id)
  (set stream-span-id nil)
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

# ── Session replay ─────────────────────────────────────────────

(defn rebuild-from-messages
  "Rebuild the chat scrollback from the current conversation messages.
   Clears existing scrollback and replays each message through output functions."
  []
  (reset-state)
  # Build a lookup of tool_use_id → tool_result for pairing
  (def messages (conv/get-messages))
  (def tool-results @{})
  (each msg messages
    (def content (get msg :content))
    (when (and (= "user" (get msg :role)) (not (string? content)))
      (each block content
        (when (= "tool_result" (get block :type))
          (put tool-results (get block :tool_use_id) block)))))
  # Replay messages
  (each msg messages
    (def role (get msg :role))
    (def content (get msg :content))
    (cond
      # User text message
      (and (= role "user") (string? content))
      (when (not (string/has-prefix? "[context]" content))
        (output-user content))
      # User tool results — already rendered inline with tool calls above
      (and (= role "user") (not (string? content)))
      nil
      # Assistant message
      (= role "assistant")
      (do
        (if (string? content)
          # Simple text response
          (output-agent (string content "\n"))
          # Complex content with text, tool_use, thinking blocks
          (do
            # Collect text blocks and render as agent output
            (def text-parts @[])
            (each block content
              (when (= "text" (get block :type))
                (array/push text-parts (get block :text ""))))
            (when (not (empty? text-parts))
              (output-agent (string (string/join text-parts "\n") "\n")))
            # Render tool calls with their results
            (each block content
              (when (= "tool_use" (get block :type))
                (def name (get block :name ""))
                (def input (get block :input @{}))
                (render-tool-call name input)
                # Find and render the corresponding result
                (def result-block (get tool-results (get block :id)))
                (when result-block
                  (def result-content (get result-block :content ""))
                  (render-tool-result name result-content))))))))))

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
      ((provider :stream-stop) (get stream-ctx :stream-id))
      (stream-end-output)
      (spinner-stop)
      (output-info "— stopped —")
      (def parser (stream-ctx :parser))
      (def response (try ((parser :finish)) ([_] nil)))
      (when (and response (get response :content))
        (conv/push {:role "assistant" :content (get response :content)}))
      (array/clear followup-queue)
      (reg/clear :steering)
      (enter-idle)
      (widget/mark-dirty :editor))
    (= mode :tools)
    (do
      (abort/abort!)
      (when (tool-exec :async-handle)
        ((get (tool-exec :async-handle) :cancel))
        (put tool-exec :async-handle nil))
      (remove-progress-lines)
      (spinner-stop)
      (output-info "— tools cancelled —")
      (array/clear steering-queue)
      (array/clear followup-queue)
      (reg/clear :steering)
      (enter-idle)
      (widget/mark-dirty :editor))))

(defn cleanup []
  (when (= mode :streaming)
    ((provider :stream-stop) (get stream-ctx :stream-id))
    (stream-end-output)
    (spinner-stop))
  (when (= mode :tools)
    (when (tool-exec :async-handle)
      ((get (tool-exec :async-handle) :cancel)))
    (spinner-stop)))

(defn tick []
  # Mailbox: when idle, drain the :steering register to start a new turn.
  # This lets external code (other agents, eval_janet) send messages by
  # pushing to (reg/push :steering "message") without user interaction.
  (when (= mode :idle)
    (def inbox (reg/drain :steering))
    (when (not (empty? inbox))
      (def msg (string/join inbox "\n"))
      (output-user msg)
      (conv/push {:role "user" :content msg})
      (def effective-prompt (build-effective-prompt))
      (try
        (start-streaming (conv/get-messages) effective-prompt)
        ([err]
         (hooks/run :on-error err)
         (output-error (string err))))))
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
          (= event-type :partial)
          (do
            # Show live progress for bash tools, spinner preview for others
            (def idx (tool-exec :current-idx))
            (def tc (get (tool-exec :tool-calls) idx))
            (if (= "bash" (tc :name))
              (do
                (update-bash-progress event-data)
                (put spinner-state :message (string "running bash…")))
              (do
                (def preview (string/slice event-data 0 (min 50 (length event-data))))
                (def truncated (if (> (length event-data) 50) "…" ""))
                (spinner-start (string "running " (tc :name) ": " preview truncated)))))
          (= event-type :error)
          (do
            (def idx (tool-exec :current-idx))
            (def tc (get (tool-exec :tool-calls) idx))
            (def result (string "Error: " event-data))
            (hooks/run :after-tool-call (tc :name) (tc :input) result)
            (remove-progress-lines)
            (spinner-stop)
            (output-tool-result result false)
            (array/push (tool-exec :results) (tool-result-msg (tc :id) result))
            (put tool-exec :async-handle nil)
            (put tool-exec :current-idx (+ idx 1))
            (start-next-tool)))))))

# ── Rendering ──────────────────────────────────────────────────

(defn- render-scrollback
  "Render the visible window of scrollback into a tui/buffer.
   Lines that exceed the viewport width wrap to the next visual row."
  [rect buf]
  (def height (rect :height))
  (def width (rect :width))
  (def total (length scrollback))

  # Leave room for spinner and partial line at bottom if active and at bottom
  (def has-partial (and (stream-state :active) (> (length (stream-state :line-buf)) 0) (= scroll-offset 0)))
  (def has-spinner (and (spinner-active?) (= scroll-offset 0)))
  (def reserved-bottom (+ (if has-spinner spinner-height 0) (if has-partial 1 0)))
  (def render-height (- height reserved-bottom))

  # Build visual rows from the bottom up until we fill the viewport.
  # scroll-offset counts visual rows to skip from the bottom.
  # Each entry is [cells row-style-key] where row-style-key is a keyword or nil.
  (def visual-rows @[])
  (var line-idx (- total 1))
  (var skip-rows scroll-offset)

  # Phase 1: Skip scroll-offset visual rows from the bottom
  (while (and (>= line-idx 0) (> skip-rows 0))
    (def line (get scrollback line-idx))
    (def eff-w (effective-width line width))
    (def rows (line-to-visual-rows-cached line eff-w))
    (def n-rows (length rows))
    (if (<= n-rows skip-rows)
      (do (set skip-rows (- skip-rows n-rows))
          (-- line-idx))
      (do
        # Partial skip: show only the top part of this line
        (def visible-rows (- n-rows skip-rows))
        (set skip-rows 0)
        (def rs (line :row-style))
        (var ri (- visible-rows 1))
        (while (and (>= ri 0) (< (length visual-rows) render-height))
          (array/push visual-rows [(get rows ri) rs])
          (-- ri))
        (-- line-idx))))

  # Phase 2: Collect visual rows for the viewport
  (while (and (>= line-idx 0) (< (length visual-rows) render-height))
    (def line (get scrollback line-idx))
    (def eff-w (effective-width line width))
    (def rows (line-to-visual-rows-cached line eff-w))
    (def rs (line :row-style))
    (var ri (- (length rows) 1))
    (while (and (>= ri 0) (< (length visual-rows) render-height))
      (array/push visual-rows [(get rows ri) rs])
      (-- ri))
    (-- line-idx))

  (def visible-count (length visual-rows))

  # Bottom-align: if content doesn't fill the viewport, offset downward
  (def y-offset (- render-height visible-count))

  # Render each visual row (visual-rows is bottom-to-top, render top-to-bottom)
  (def row-end (+ (rect :x) width))
  (def blank-style (tui/style))
  (for i 0 visible-count
    (def [row rs] (get visual-rows (- visible-count 1 i)))
    (def y (+ (rect :y) y-offset i))
    # Content starts 1 column right of the gutter for styled rows
    (def content-x (if rs (+ (rect :x) 1) (rect :x)))
    (var col content-x)
    (each cell row
      (when (>= col row-end) (break))
      (def ch (cell :text))
      (def w (tui/char-width ch))
      (when (and (> w 1) (> (+ col w) row-end)) (break))
      (tui/buffer-set-char buf col y ch (cell :style))
      (when (= w 2)
        (when (< (+ col 1) row-end)
          (tui/buffer-set-char buf (+ col 1) y "" (cell :style))))
      (+= col (max w 1)))
    (when rs
      (def gutter-color
        (cond
          (= rs :user-row-bg) (colors :user-label)
          (= rs :agent-row-bg) (colors :agent-label)
          (= rs :thinking-row-bg) (colors :thinking-label)
          (colors :tool-label)))
      (tui/buffer-set-char buf (rect :x) y "▐" gutter-color)))

  # Render the in-progress streaming line (partial line not yet newline-terminated)
  (when has-partial
    (def partial-text (string (stream-state :line-buf)))
    # Render just below the scrollback content (in the reserved area)
    (def partial-y (+ (rect :y) y-offset visible-count))
    (when (< partial-y (+ (rect :y) height))
      (tui/buffer-set-char buf (rect :x) partial-y "▐" (colors :agent-label))
      (if (stream-state :first)
        (do
          (def label-style (colors :agent-label))
          (def text-style (tui/style))
          (tui/buffer-set-string buf (+ (rect :x) 1) partial-y "   gent: " label-style)
          (tui/buffer-set-string buf (+ (rect :x) 10) partial-y partial-text text-style))
        (do
          (def style (tui/style))
          (tui/buffer-set-string buf (+ (rect :x) 1) partial-y (string "         " partial-text) style)))))

  # Render spinner (3-row gentleman) at bottom when active and scrolled to bottom
  (when (and (spinner-active?) (= scroll-offset 0))
    (def frame (get spinner-frames (spinner-state :frame)))
    (def msg (spinner-state :message))
    (def style (colors :separator))
    (def y-base (+ (rect :y) (- height spinner-height)))
    (def x (rect :x))
    # Draw face and message on a single row
    (tui/buffer-set-string buf x y-base frame style)
    (tui/buffer-set-string buf (+ x spinner-gent-width 1) y-base msg style))

  # Streaming dirty-row optimization: when scrollback hasn't changed and
  # the visual layout is stable, only the partial line and spinner rows
  # need diffing. Mark all other rows clean so the Rust diff skips them.
  (def sb-dirty scrollback-dirty)
  (set scrollback-dirty false)
  (when (and (buf :dirty-rows)
             (stream-state :active)
             (= scroll-offset 0)
             (not sb-dirty)
             (= y-offset prev-y-offset)
             (= render-height prev-render-height))
    (def dr (buf :dirty-rows))
    (def dr-len (length dr))
    (for i 0 dr-len (put dr i false))
    (when has-partial
      (def partial-row (- (+ y-offset visible-count) (rect :y)))
      (when (and (>= partial-row 0) (< partial-row dr-len))
        (put dr partial-row true)))
    (when has-spinner
      (def spinner-start (- height spinner-height))
      (for i spinner-start height
        (when (< i dr-len) (put dr i true)))))
  (set prev-y-offset y-offset)
  (set prev-render-height render-height))

# ── Widget constructor ─────────────────────────────────────────

(defn create []
  # Register hook to clear scrollback when conversation is cleared
  (hooks/add :conversation-clear
    (fn [] (reset-state)))
  
  @{:name :chat
    :state @{}
    :rect nil
    :content-rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[]

    :handle (fn [self event]
             (def etype (get event :type))
             # Handle arrow keys when focused for message navigation
             (when (and (= etype :key) (get self :focused))
               (def key (get event :key))
               (def cr (or (self :content-rect) (self :rect)))
               (def width (if cr (cr :width) 80))
               (def height (if cr (cr :height) 10))
               (def max-offset (max 0 (- (total-visual-rows width) height)))
               (cond
                 (= key :up)
                 # Navigate up (scroll up by 1 line, clamped at top)
                 (do
                   (set scroll-offset (min max-offset (+ scroll-offset 1)))
                   (widget/mark-dirty :chat)
                   (break nil))

                 (= key :down)
                 # Navigate down (scroll down by 1 line, clamped at bottom)
                 (do
                   (set scroll-offset (max 0 (- scroll-offset 1)))
                   (widget/mark-dirty :chat)
                   (break nil))

                 (= key :pageup)
                 (do
                   (def page-size (max 1 (- height 2)))
                   (set scroll-offset (min max-offset (+ scroll-offset page-size)))
                   (widget/mark-dirty :chat)
                   (break nil))

                 (= key :pagedown)
                 (do
                   (def page-size (max 1 (- height 2)))
                   (set scroll-offset (max 0 (- scroll-offset page-size)))
                   (widget/mark-dirty :chat)
                   (break nil))

                 (or (= key :end) (= key "G"))
                 (do
                   (set scroll-offset 0)
                   (widget/mark-dirty :chat)
                   (break nil))

                 (= key :home)
                 (do
                   (set scroll-offset (max 0 (- (total-visual-rows width) height)))
                   (widget/mark-dirty :chat)
                   (break nil))))

             (cond
               (= etype :submit) (submit (event :text))
               (= etype :stop) (stop)
               (= etype :scroll-up)
               (let [cr (or (self :content-rect) (self :rect))
                     width (if cr (cr :width) 80)
                     height (if cr (cr :height) 10)
                     page-size (max 1 (- height 2))
                     max-offset (max 0 (- (total-visual-rows width) height))]
                 (set scroll-offset (min max-offset (+ scroll-offset page-size)))
                 (widget/mark-dirty :chat))
               (= etype :scroll-down)
               (let [cr (or (self :content-rect) (self :rect))]
                 (def page-size (if cr (max 1 (- (cr :height) 2)) 10))
                 (set scroll-offset (max 0 (- scroll-offset page-size)))
                 (widget/mark-dirty :chat))
               (= etype :scroll-line-up)
               (let [cr (or (self :content-rect) (self :rect))
                     width (if cr (cr :width) 80)
                     height (if cr (cr :height) 10)
                     n (or (get event :lines) 1)
                     max-offset (max 0 (- (total-visual-rows width) height))
                     old-offset scroll-offset]
                 (set scroll-offset (min max-offset (+ scroll-offset n)))
                 (widget/mark-dirty :chat)
                 (def actual (- scroll-offset old-offset))
                 (when (> actual 0) [:scroll-optimized actual :up]))
               (= etype :scroll-line-down)
               (let [n (or (get event :lines) 1)
                     old-offset scroll-offset]
                 (set scroll-offset (max 0 (- scroll-offset n)))
                 (widget/mark-dirty :chat)
                 (def actual (- old-offset scroll-offset))
                 (when (> actual 0) [:scroll-optimized actual :down]))
               (= etype :toggle-thinking)
               (do
                 # Only toggle when idle to prevent rendering artifacts
                 (when (= mode :idle)
                   (toggle-thinking-visibility)))))

    :update (fn [self] (tick))

    :render (fn [self rect buf]
             (def border-color
               (if (self :focused)
                 (tui/color-indexed 75)
                 (tui/color-indexed 240)))
             (def blk (tui/block :title " Chat " :borders :all :border-type :rounded
                                  :border-style (tui/style :fg border-color)))
             (tui/render blk rect buf)
             (def inner (tui/block-inner blk rect))
             (put self :content-rect inner)
             (when (and (> (inner :height) 0) (> (inner :width) 0))
               (render-scrollback inner buf)
               # Scrollbar and indicator when scrolled up
               (when (> scroll-offset 0)
                 (def total-vrows (total-visual-rows (inner :width)))
                 (def max-off (max 1 (- total-vrows (inner :height))))
                 (def track-height (inner :height))
                 (def thumb-size (max 1 (math/floor (* track-height (/ (inner :height) (max 1 total-vrows))))))
                 (def thumb-pos (math/floor (* (- track-height thumb-size) (/ (- max-off scroll-offset) (max 1 max-off)))))
                 (def right-col (- (+ (rect :x) (rect :width)) 1))
                 (def track-y (+ (rect :y) 1))
                 (def scroll-style (tui/style :fg (tui/color-indexed 240)))
                 (def thumb-style (tui/style :fg (tui/color-indexed 75)))
                 (for i 0 track-height
                   (def y (+ track-y i))
                   (if (and (>= i thumb-pos) (< i (+ thumb-pos thumb-size)))
                     (tui/buffer-set-char buf right-col y "\xE2\x96\x88" thumb-style)
                     (tui/buffer-set-char buf right-col y "\xE2\x96\x91" scroll-style)))
                 # "N below" indicator on bottom border
                 (def indicator (string/format " %d below " scroll-offset))
                 (def ind-width (tui/string-width indicator))
                 (def ix (- (+ (rect :x) (rect :width)) ind-width 1))
                 (def iy (- (+ (rect :y) (rect :height)) 1))
                 (tui/buffer-set-string buf ix iy indicator (tui/style :fg (tui/color-indexed 75))))))})
