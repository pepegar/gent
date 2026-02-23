# The reactor — gent's event loop.
#
# A thin dispatcher that polls events and routes them to widgets.
# All agent logic lives in widgets (chat, editor, separator).
# This is the equivalent of Emacs's command loop.
#
# Rendering pipeline:
#   1. Create a full-screen tui/buffer
#   2. Each dirty widget renders into its rect within the buffer
#   3. Diff against the previous frame buffer
#   4. Emit only changed cells to the terminal
#   5. Swap buffers (double-buffering)

(import core/widget :as widget)
(import core/ui :as ui)
(import core/hooks :as hooks)
(import core/conversation :as conv)
(import core/commands :as commands)
(import core/registers :as reg)
(import core/skills :as skills)
(import core/agents-md :as agents-md)
(import core/editor :as editor)
(import tui)
(import widgets/chat :as chat)
(import widgets/editor :as editor-w)
(import widgets/separator :as sep)

# ── Layout ─────────────────────────────────────────────────────

(defn- default-layout
  "Default layout: chat on top, separator, editor at bottom."
  [area]
  (def [chat-area sep-area editor-area] (tui/vsplit area :fill 1 1))
  @{:chat chat-area :separator sep-area :editor editor-area})

(defn- sync-ui-layout
  "Sync widget layout back to core/ui for backward compatibility."
  []
  (def layout (ui/get-layout))
  (when-let [chat-w (widget/get-widget :chat)]
    (when (chat-w :rect)
      (def r (chat-w :rect))
      (put layout :output-bottom (+ (r :y) (r :height)))))
  (when-let [sep-w (widget/get-widget :separator)]
    (when (sep-w :rect)
      (def r (sep-w :rect))
      (put layout :separator-row (+ (r :y) 1))))
  (when-let [ed-w (widget/get-widget :editor)]
    (when (ed-w :rect)
      (def r (ed-w :rect))
      (put layout :input-row (+ (r :y) 1)))))

# ── Double buffering ───────────────────────────────────────────

(var- prev-buf nil)
(var- screen-area nil)

(defn- refresh-and-layout
  "Refresh terminal size, do widget layout, sync, create buffers."
  []
  (ui/refresh-layout)
  (def layout (ui/get-layout))
  (def area (tui/rect 0 0 (layout :cols) (layout :rows)))
  (set screen-area area)
  (widget/do-layout area)
  (sync-ui-layout)
  # Reset double-buffering on resize (full redraw)
  (set prev-buf nil))

(defn- render-frame
  "Render all dirty widgets into a fresh buffer, diff against previous, flush."
  []
  (when (nil? screen-area) (break))
  (def buf (tui/buffer screen-area))

  # Render all widgets into the buffer
  (each name (widget/list-widgets)
    (when-let [w (widget/get-widget name)]
      (when (and (w :rect) (w :render))
        # Always render into fresh buffer (dirty tracking is per-widget)
        ((w :render) w (w :rect) buf)
        (put w :dirty false))))

  # Diff and flush
  (if prev-buf
    (do
      (def diff (tui/buffer-diff prev-buf buf))
      (when (not= "" diff)
        (term/write diff)))
    # First frame or after resize — full render
    (term/write (tui/buffer->str buf)))

  # Swap
  (set prev-buf buf)

  # Restore cursor to editor position
  (def ed-w (widget/get-widget :editor))
  (when (and ed-w (ed-w :rect))
    (def r (ed-w :rect))
    (editor/redraw)))

# ── Eval ───────────────────────────────────────────────────────

(defn- eval-janet-inline [code]
  (try
    (do
      (def result (eval-string code))
      (def result-str
        (if (or (string? result) (number? result) (boolean? result) (nil? result))
          (string result)
          (string/format "%q" result)))
      (chat/output-eval code result-str))
    ([err]
      (chat/output-eval code nil)
      (chat/output-error (string err))))
  (widget/mark-dirty :separator)
  (widget/mark-dirty :editor))

# ── Startup banner ─────────────────────────────────────────────

(defn- display-banner []
  (chat/output-info "gent — the extensible coding agent")
  (chat/output-info (string "  " (length (tools/list-registered)) " tools loaded — ctrl-c to quit"))
  (def skill-list (skills/list-skills))
  (when (not (empty? skill-list))
    (chat/output-info (string "  " (length skill-list) " skills:"))
    (each s (sort-by |($ :name) skill-list)
      (chat/output-info (string "    • " (s :name) " — " (s :path)))))
  (def agents-md-files (agents-md/list-files))
  (when (not (empty? agents-md-files))
    (chat/output-info (string "  " (length agents-md-files) " AGENTS.md:"))
    (each path agents-md-files
      (chat/output-info (string "    • " path))))
  (def loaded-configs (or (reg/get :loaded-configs) @[]))
  (when (not (empty? loaded-configs))
    (chat/output-info (string "  " (length loaded-configs) " config:"))
    (each path loaded-configs
      (chat/output-info (string "    • " path)))))

# ── Reactor ────────────────────────────────────────────────────

(defn run
  "Main reactor loop."
  []
  # Set up TUI — alternate screen, raw mode, mouse capture
  (term/enable-raw-mode)
  (term/write "\x1b[?1049h")  # enter alternate screen buffer
  (term/write "\x1b[2J")      # clear screen
  (term/write "\x1b[?25h")    # show cursor
  (term/write "\x1b[?1000h")  # enable mouse button tracking (includes scroll)
  (term/write "\x1b[?1006h")  # enable SGR extended mouse mode
  (defer (do
    (term/write "\x1b[?1006l")  # disable SGR mouse mode
    (term/write "\x1b[?1000l")  # disable mouse tracking
    (term/write "\x1b[?25h")
    (term/write "\x1b[?1049l")  # leave alternate screen buffer
    (term/disable-raw-mode))

    # Initialize ui layout (for backward compat — editor uses it)
    (ui/refresh-layout)

    # Create and register widgets
    (widget/register (chat/create))
    (widget/register (sep/create))
    (widget/register (editor-w/create))

    # Set layout
    (widget/set-layout-fn default-layout)
    (refresh-and-layout)

    # Focus the editor
    (widget/focus :editor)

    # Status provider for separator
    (sep/set-status-provider
      (fn []
        (string "session: " (conv/get-session-id)
                " │ " (conv/length) " msgs"
                " ≈ " (conv/estimate-tokens) " tokens")))

    # Hook: mark separator dirty on conversation changes
    (hooks/add :after-message (fn [_] (widget/mark-dirty :separator)))

    (hooks/add :before-send
      (fn [conversation]
        (def tokens (conv/estimate-tokens))
        (when (> tokens 180000)
          (chat/output-info
            (string "⚠ context window ~" tokens " tokens — consider /clear or /rollback")))))

    # Startup banner
    (display-banner)

    # Initialize conversation
    (def sid (conv/init))
    (chat/output-info (string "  session: " sid))
    (chat/output "")

    # Initial render
    (widget/mark-all-dirty)
    (render-frame)

    # ── The reactor loop ───────────────────────────────────────
    (while true
      # 1. Determine poll timeout
      (def timeout (if (chat/active?) 16 nil))

      # 2. Poll terminal event
      (def ev (term/read-event timeout))

      # 3. Handle terminal event
      (when ev
        (def ev-type (get ev :type))
        (cond
          (= :resize ev-type)
          # Resize — refresh layout, full redraw
          (do
            (refresh-and-layout)
            (widget/mark-all-dirty))

          (= :scroll ev-type)
          # Mouse scroll → coalesce all pending scroll events into one batch
          (do
            (var scroll-delta (if (= :up (get ev :direction)) 1 -1))
            (var next (term/read-event 0))
            (while (and next (= :scroll (get next :type)))
              (if (= :up (get next :direction)) (++ scroll-delta) (-- scroll-delta))
              (set next (term/read-event 0)))
            # Apply the accumulated delta as a single dispatch
            (when (> scroll-delta 0)
              (widget/dispatch :chat {:type :scroll-line-up :lines scroll-delta}))
            (when (< scroll-delta 0)
              (widget/dispatch :chat {:type :scroll-line-down :lines (math/abs scroll-delta)}))
            # If we read a non-scroll event, handle it next iteration
            # by pushing it back — but term has no pushback, so handle inline
            (when next
              (def next-type (get next :type))
              (cond
                (= :resize next-type)
                (do (refresh-and-layout) (widget/mark-all-dirty))
                # Key events → editor
                (= :key next-type)
                (widget/dispatch :editor next))))

          # All other events → editor widget
          (do
            (def result (widget/dispatch :editor ev))
            (cond
              (= result :quit)
              (do (chat/cleanup) (break))

              (= result :stop)
              (chat/stop)

              (string? result)
              (when (not= "" result)
                (def cmd-result (commands/dispatch result))
                (if (get cmd-result :handled)
                  (do
                    (chat/output-user result)
                    (def r (get cmd-result :result))
                    (when (and r (not= "" r))
                      (each line (string/split "\n" r)
                        (chat/output-info line)))
                    (widget/mark-dirty :separator))
                  (chat/submit result)))

              (and (tuple? result) (= :eval (first result)))
              (do
                (def code (get result 1))
                (when (and code (not= "" code))
                  (eval-janet-inline code)))

              # Scroll signals → chat widget
              (= result :scroll-up)
              (widget/dispatch :chat {:type :scroll-up})

              (= result :scroll-down)
              (widget/dispatch :chat {:type :scroll-down})

              (= result :scroll-line-up)
              (widget/dispatch :chat {:type :scroll-line-up})

              (= result :scroll-line-down)
              (widget/dispatch :chat {:type :scroll-line-down})))))

      # 4. Update all widgets (chat drains stream, polls tools)
      (widget/update-all)

      # 5. Tick widget timers
      (widget/tick-timers)

      # 6. Render frame (diff-based)
      (render-frame))))
