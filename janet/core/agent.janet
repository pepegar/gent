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
(import widgets/editor :as editor)
(import tui)
(import widgets/chat :as chat)
(import widgets/editor :as editor-w)
(import widgets/separator :as sep)
(import core/completion :as completion)

# ── Layout ─────────────────────────────────────────────────────

(defn- default-layout
  "Default layout: chat on top, separator, editor at bottom."
  [area]
  (def ed-height (editor/get-height))
  (def [chat-area sep-area editor-area] (tui/vsplit area :fill 1 ed-height))
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
      (put layout :input-row (+ (r :y) (r :height)))
      (put layout :editor-height (r :height)))))

# ── Double buffering ───────────────────────────────────────────

(var- prev-buf nil)
(var- screen-area nil)
(var- popup-was-visible false)

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
  "Render dirty widgets, diff against previous frame, flush."
  []
  (when (nil? screen-area) (break))

  # If the popup was visible last frame, force-repaint the widgets it
  # overlapped so their clean cells overwrite the stale popup in prev-buf.
  (when popup-was-visible
    (widget/mark-dirty :chat)
    (widget/mark-dirty :separator)
    (set popup-was-visible false))

  (if (nil? prev-buf)
    # First frame or after resize — full render
    (do
      (def buf (tui/buffer screen-area))
      (each name (widget/list-widgets)
        (when-let [w (widget/get-widget name)]
          (when (and (w :rect) (w :render))
            ((w :render) w (w :rect) buf)
            (put w :dirty false))))
      (term/write (tui/buffer->str buf))
      (set prev-buf buf))

    # Incremental: render only dirty widget rects, diff just those areas
    (do
      (each name (widget/list-widgets)
        (when-let [w (widget/get-widget name)]
          (when (and (w :dirty) (w :rect) (w :render))
            (def r (w :rect))
            # Render into a small buffer covering just this widget's rect
            (def small-buf (tui/buffer r))
            ((w :render) w r small-buf)
            (put w :dirty false)
            # Diff this rect between prev-buf and small-buf, emit changes
            (def parts @[])
            (var cur-style nil)
            (var expected-col nil)
            (for row 0 (r :height)
              (def y (+ (r :y) row))
              (set expected-col nil)
              (for col 0 (r :width)
                (def x (+ (r :x) col))
                (def old-c (tui/buffer-get prev-buf x y))
                (def new-c (tui/buffer-get small-buf x y))
                (unless (and (= (old-c :ch) (new-c :ch))
                             (deep= (old-c :style) (new-c :style)))
                  (when (or (nil? expected-col) (not= col expected-col))
                    (array/push parts
                      (string/format "\x1b[%d;%dH" (+ y 1) (+ x 1))))
                  (def st (new-c :style))
                  (when (not (deep= st cur-style))
                    (array/push parts "\x1b[0m")
                    (def sgr (tui/style->sgr st))
                    (when (not= sgr "") (array/push parts sgr))
                    (set cur-style st))
                  (array/push parts (new-c :ch))
                  (set expected-col (+ col 1))
                  # Update prev-buf in place
                  (tui/buffer-set-char prev-buf x y (new-c :ch) (new-c :style)))))
            (when (not (empty? parts))
              (array/push parts "\x1b[0m")
              (term/write (string ;parts))))))))

  # Render completion popup overlay (if active)
  (when (and prev-buf screen-area (completion/active?))
    (def [cursor-row cursor-col] (editor/get-cursor-screen-pos))
    (when (and cursor-row cursor-col)
      (def popup (completion/render-popup cursor-row cursor-col screen-area))
      (when popup
        (set popup-was-visible true)
        (def parts @[])
        (var cur-style nil)
        (each cell (popup :cells)
          (def x (cell :x))
          (def y (cell :y))
          (array/push parts (string/format "\x1b[%d;%dH" (+ y 1) (+ x 1)))
          (def st (cell :style))
          (when (not (deep= st cur-style))
            (array/push parts "\x1b[0m")
            (def sgr (tui/style->sgr st))
            (when (not= sgr "") (array/push parts sgr))
            (set cur-style st))
          (array/push parts (cell :ch))
          (tui/buffer-set-char prev-buf x y (cell :ch) st))
        (when (not (empty? parts))
          (array/push parts "\x1b[0m")
          (term/write (string ;parts))))))

  # Restore cursor to editor position
  (editor/redraw))

(defn force-rerender
  "Force a full screen redraw on the next frame."
  []
  (set prev-buf nil)
  (widget/mark-all-dirty))

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
  (term/write "\x1b[>1u")     # enable Kitty keyboard protocol (disambiguate Shift+Enter etc.)
  (defer (do
    (term/write "\x1b[<u")      # pop Kitty keyboard enhancement flags
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
          # Batch key events for paste performance: drain all pending
          # key events before rendering, like we do for scroll events.
          (do
            (editor/batch-begin)
            (var result (widget/dispatch :editor ev))
            (var leftover nil)
            (when (nil? result)
              (var next-ev (term/read-event 0))
              (while (and next-ev (= :key (get next-ev :type)))
                (set result (widget/dispatch :editor next-ev))
                (when result (break))
                (set next-ev (term/read-event 0)))
              (when (and next-ev (nil? result))
                (set leftover next-ev)))
            (editor/batch-end)

            # Handle any leftover non-key event from the drain
            (when leftover
              (def lt (get leftover :type))
              (cond
                (= :resize lt)
                (do (refresh-and-layout) (widget/mark-all-dirty))
                (= :scroll lt)
                (do
                  (def dir (get leftover :direction))
                  (widget/dispatch :chat
                    {:type (if (= :up dir) :scroll-line-up :scroll-line-down)}))))

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
              (widget/dispatch :chat {:type :scroll-line-down})

              (= result :rerender)
              (force-rerender)))))

      # 4. Update all widgets (chat drains stream, polls tools)
      (widget/update-all)

      # 5. Tick widget timers
      (widget/tick-timers)

      # 6. Re-layout if editor height changed
      (when (not= (editor/get-height) (or ((ui/get-layout) :editor-height) 1))
        (refresh-and-layout)
        (widget/mark-all-dirty))

      # 7. Render frame (diff-based)
      (render-frame))))
