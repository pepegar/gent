# The reactor — gent's event loop.
#
# A thin dispatcher that polls events and routes them to widgets.
# All agent logic lives in widgets (chat, editor, filepicker).
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
(import core/input-history :as ih)
(import widgets/editor :as editor)
(import tui)
(import widgets/chat :as chat)
(import widgets/editor :as editor-w)
(import core/completion :as completion)
(import core/dialog :as dialog)
(import core/profile :as profile)
(import core/rpc-server :as rpc-srv)

# ── Layout ─────────────────────────────────────────────────────

(def- default-layout-data
  @[{:constraint :fill
     :children [{:widget :chat :constraint :fill}]}
    {:widget :editor :constraint |(editor/get-height)}])

(defn- sync-ui-layout
  "Sync widget layout back to core/ui for backward compatibility."
  []
  (def layout (ui/get-layout))
  (when-let [chat-w (widget/get-widget :chat)]
    (when (chat-w :rect)
      (def r (chat-w :rect))
      (put layout :output-bottom (+ (r :y) (r :height)))))
  (when-let [ed-w (widget/get-widget :editor)]
    (when (ed-w :rect)
      (def r (ed-w :rect))
      (put layout :input-row (+ (r :y) (r :height)))
      (put layout :editor-height (r :height)))))

# ── Double buffering ───────────────────────────────────────────

(var- prev-buf nil)
(var- screen-area nil)
(var- widget-bufs @{})
(var- popup-was-visible false)
(var- pending-scroll-opt nil)
(var- should-quit false)

(defn- scroll-region-optimize
  "Apply terminal scroll region optimization for the chat widget.
   Shifts terminal content and prev-buf cells so only N new rows need diffing."
  [delta direction]
  (when (nil? prev-buf) (break false))
  (when popup-was-visible (break false))
  (when (completion/active?) (break false))
  (when (dialog/active?) (break false))

  (def chat-w (widget/get-widget :chat))
  (when (nil? chat-w) (break false))
  (def cr (or (chat-w :content-rect) (chat-w :rect)))
  (when (nil? cr) (break false))

  (def rh (cr :height))
  (when (> delta (math/floor (/ rh 2))) (break false))

  (def ry (cr :y))
  (def rx (cr :x))
  (def rw (cr :width))
  (def cells (prev-buf :cells))
  (def pa (prev-buf :area))
  (def pw (pa :width))

  # Terminal scroll region escape sequences
  (def top (+ ry 1))
  (def bottom (+ ry rh))
  (term/write (string/format "\x1b[%d;%dr" top bottom))
  (if (= direction :up)
    (term/write (string/format "\x1b[%dT" delta))
    (term/write (string/format "\x1b[%dS" delta)))
  (term/write "\x1b[r")

  # Shift prev-buf cells within the chat rect (copy values, not references,
  # to avoid aliasing bugs when the diff later updates cells in-place)
  (if (= direction :up)
    (do
      # Content moves DOWN: shift rows down, new content at top
      (var row (- rh 1))
      (while (>= row delta)
        (for col 0 rw
          (def src-idx (+ (* (+ ry (- row delta)) pw) rx col))
          (def dst-idx (+ (* (+ ry row) pw) rx col))
          (def src (get cells src-idx))
          (def dst (get cells dst-idx))
          (put dst :ch (src :ch))
          (put dst :style (src :style)))
        (-- row))
      (for row 0 delta
        (for col 0 rw
          (def idx (+ (* (+ ry row) pw) rx col))
          (def c (get cells idx))
          (put c :ch " ")
          (put c :style tui/style-default))))
    (do
      # Content moves UP: shift rows up, new content at bottom
      (for row 0 (- rh delta)
        (for col 0 rw
          (def src-idx (+ (* (+ ry (+ row delta)) pw) rx col))
          (def dst-idx (+ (* (+ ry row) pw) rx col))
          (def src (get cells src-idx))
          (def dst (get cells dst-idx))
          (put dst :ch (src :ch))
          (put dst :style (src :style))))
      (for row (- rh delta) rh
        (for col 0 rw
          (def idx (+ (* (+ ry row) pw) rx col))
          (def c (get cells idx))
          (put c :ch " ")
          (put c :style tui/style-default)))))

  (set pending-scroll-opt {:delta delta :direction direction :height rh})
  true)

(defn- refresh-and-layout
  "Refresh terminal size, do widget layout, sync, create buffers."
  []
  (ui/refresh-layout)
  (def layout (ui/get-layout))
  (def area (tui/rect 0 0 (layout :cols) (layout :rows)))
  (set screen-area area)
  (widget/do-layout area)
  (sync-ui-layout)
  (set prev-buf nil)
  (set widget-bufs @{}))

(defn- render-frame
  "Render dirty widgets, diff against previous frame, flush."
  []
  (when (nil? screen-area) (break))

  # When a popup was visible last frame, force-repaint the widgets it
  # overlapped so clean cells overwrite stale popup remnants in prev-buf.
  # This handles both popup disappearance AND popup resize/reposition —
  # without it, old border cells linger when the popup changes shape.
  (when popup-was-visible
    (widget/mark-dirty :chat)
    (widget/mark-dirty :editor)
    (set pending-scroll-opt nil)
    (unless (or (dialog/active?) (completion/active?))
      (set popup-was-visible false)))

  # Accumulate all frame output into a single buffer for atomic write.
  # This prevents flicker when popup overlays cover widget areas — without
  # batching, the widget diff would briefly flash through the popup before
  # the overlay redraws on top.
  (def frame-out @"")

  (if (nil? prev-buf)
    # First frame or after resize — full render
    (do
      (set pending-scroll-opt nil)
      (def buf (tui/buffer screen-area))
      (each name (widget/list-widgets)
        (when-let [w (widget/get-widget name)]
          (when (and (w :rect) (w :render))
            (profile/with-span (string "render:" (string name)) "render"
              (fn [] ((w :render) w (w :rect) buf)))
            (put w :dirty false))))
      (buffer/push frame-out (tui/buffer->str buf))
      (set prev-buf buf))

    # Incremental: render only dirty widget rects, diff just those areas
    (do
      (each name (widget/list-widgets)
        (when-let [w (widget/get-widget name)]
          (when (and (w :dirty) (w :rect) (w :render))
            (def r (w :rect))
            (def cached (get widget-bufs name))
            (def small-buf
              (if (and cached (= (cached :area) r))
                (tui/buffer-clear cached)
                (let [b (tui/buffer r true)]
                  (put widget-bufs name b)
                  b)))
            (profile/with-span (string "render:" (string name)) "render"
              (fn [] ((w :render) w r small-buf)))
            (put w :dirty false)
            # After scroll-region-optimize, only the N new rows need diffing
            (when (and pending-scroll-opt (= name :chat))
              (def info pending-scroll-opt)
              (set pending-scroll-opt nil)
              (when-let [dr (small-buf :dirty-rows)]
                (for i 0 (length dr) (put dr i false))
                (def delta (info :delta))
                (if (= (info :direction) :up)
                  (for i 0 (min delta (length dr)) (put dr i true))
                  (for i (max 0 (- (length dr) delta)) (length dr) (put dr i true)))))
            (def diff-str (buffer/diff prev-buf small-buf r))
            (when (not= "" diff-str) (buffer/push frame-out diff-str)))))))

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
          (when (not (tui/style= st cur-style))
            (array/push parts "\x1b[0m")
            (def sgr (tui/style->sgr st))
            (when (not= sgr "") (array/push parts sgr))
            (set cur-style st))
          (array/push parts (cell :ch))
          (tui/buffer-set-char prev-buf x y (cell :ch) st))
        (when (not (empty? parts))
          (array/push parts "\x1b[0m")
          (buffer/push frame-out (string ;parts))))))

  # Render dialog overlay (if active)
  (when (and prev-buf screen-area (dialog/active?))
    (def popup (dialog/render-overlay screen-area))
    (when popup
      (set popup-was-visible true)
      (def parts @[])
      (var cur-style nil)
      (each cell (popup :cells)
        (def x (cell :x))
        (def y (cell :y))
        (array/push parts (string/format "\x1b[%d;%dH" (+ y 1) (+ x 1)))
        (def st (cell :style))
        (when (not (tui/style= st cur-style))
          (array/push parts "\x1b[0m")
          (def sgr (tui/style->sgr st))
          (when (not= sgr "") (array/push parts sgr))
          (set cur-style st))
        (array/push parts (cell :ch))
        (tui/buffer-set-char prev-buf x y (cell :ch) st))
      (when (not (empty? parts))
        (array/push parts "\x1b[0m")
        (buffer/push frame-out (string ;parts)))))

  # Flush all frame output in a single atomic write
  (when (> (length frame-out) 0)
    (term/write (string frame-out)))

  # Restore cursor to editor position
  (editor/redraw))

(defn force-rerender
  "Force a full screen redraw on the next frame."
  []
  (refresh-and-layout)
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
  (widget/mark-dirty :editor)
  (widget/mark-dirty :editor))

# ── Startup banner ─────────────────────────────────────────────

(defn- display-banner []
  (def version-str
    (let [v (or (dyn :gent/version) "dev")
          h (or (dyn :gent/git-hash) "")]
      (if (not= h "")
        (string "gent " v " (" h ")")
        (string "gent " v))))
  (chat/output-info version-str)
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
  "Main reactor loop. Optional rpc-port starts a JSON-RPC server alongside the TUI."
  [&opt rpc-port]
  # Set up TUI — alternate screen, raw mode (no mouse capture)
  (term/enable-raw-mode)
  (term/write "\x1b[?1049h")  # enter alternate screen buffer
  (term/write "\x1b[2J")      # clear screen
  (term/write "\x1b[?25h")    # show cursor
  (term/write "\x1b[>1u")     # enable Kitty keyboard protocol (disambiguate Shift+Enter etc.)
  (defer (do
          (term/write "\x1b[<u")      # pop Kitty keyboard enhancement flags
          (term/write "\x1b[?25h")
          (term/write "\x1b[?1049l")  # leave alternate screen buffer
          (term/disable-raw-mode))

    # Initialize ui layout (for backward compat — editor uses it)
    (ui/refresh-layout)

    # Create and register widgets
    (widget/register (chat/create))
    (widget/register (editor-w/create))

    # Register built-in named layout: focus = distraction-free chat + editor
    (widget/register-layout :focus default-layout-data)

    # Set layout (only if user config hasn't already set one via -l etc.)
    (unless (widget/has-layout?)
      (widget/set-layout-data default-layout-data))

    # Snapshot whatever layout is active (after user config) as :default
    (widget/register-layout :default (widget/get-layout-data))

    (widget/clear-layout-dirty)
    (refresh-and-layout)

    # Focus the editor
    (widget/focus :editor)

    # Status provider for editor border title
    (editor/set-status-provider
      (fn [&opt max-w]
        (default max-w 999)
        (def focused-w (widget/focused))
        (def focus-name (if focused-w (string (get focused-w :name)) "none"))
        (def sid (conv/get-session-id))
        (def msgs (conv/length))
        (def tokens (conv/estimate-tokens))
        # Progressive disclosure: full → medium → short → minimal
        (def full (string "focus: " focus-name
                          " │ " msgs " msgs"
                          " ≈ " tokens " tokens"
                          " │ " sid))
        (if (<= (tui/string-width full) max-w)
          full
          (do
            (def medium (string focus-name " │ " msgs " msgs ≈ " tokens "t"))
            (if (<= (tui/string-width medium) max-w)
              medium
              (do
                (def short (string msgs " msgs ≈ " tokens "t"))
                (if (<= (tui/string-width short) max-w)
                  short
                  (string tokens "t"))))))))

    # Hook: mark editor dirty on conversation changes (updates title)
    (hooks/add :after-message (fn [_] (widget/mark-dirty :editor)))

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

    # Load cross-session input history
    (ih/init (conv/project-sessions-dir))

    # Optional RPC server (when --port is specified without --headless)
    (var rpc-server nil)
    (when rpc-port
      (def srv (rpc-srv/start rpc-port))
      (when srv
        (rpc-srv/install-hooks srv)
        (chat/output-info (string "  rpc: listening on port " rpc-port))
        (set rpc-server srv)))

    # Initial render
    (widget/mark-all-dirty)
    (render-frame)

    # ── The reactor loop ───────────────────────────────────────
    (set should-quit false)
    (while (not should-quit)
      (profile/with-span "reactor:loop" "reactor" (fn []

      # 1. Determine poll timeout
      # Use short timeout when active or when RPC clients are connected
      # so we don't block on terminal events and starve TCP reads.
                                                   (def timeout
                                                     (cond
                                                       (chat/active?) 16
                                                       (and rpc-server (rpc-srv/has-clients? rpc-server)) 50
                                                       rpc-server 100
                                                       nil))

      # 2. Poll terminal event
                                                   (def ev (profile/with-span "event:poll" "io" (fn [] (term/read-event timeout))))

      # 3. Handle terminal event
                                                   (when ev
                                                     (def ev-type (get ev :type))
                                                     (cond
                                                       (= :resize ev-type)
                                                       # Resize — refresh layout, full redraw
                                                       (profile/with-span "event:resize" "event" (fn []
                                                                                                  (refresh-and-layout)
                                                                                                  (widget/mark-all-dirty)))

                                                       (= :scroll ev-type)
                                                       # Mouse scroll → coalesce all pending scroll events into one batch
                                                       (do
                                                         (var scroll-delta (if (= :up (get ev :direction)) 1 -1))
                                                         (var next (term/read-event 0))
                                                         (while (and next (= :scroll (get next :type)))
                                                           (if (= :up (get next :direction)) (++ scroll-delta) (-- scroll-delta))
                                                           (set next (term/read-event 0)))
                                                         (var scroll-result nil)
                                                         (profile/with-span-meta "event:scroll" "event"
                                                           @{:coalesced (math/abs scroll-delta)}
                                                           (fn []
                                                             (when (> scroll-delta 0)
                                                               (set scroll-result (widget/dispatch :chat {:type :scroll-line-up :lines scroll-delta})))
                                                             (when (< scroll-delta 0)
                                                               (set scroll-result (widget/dispatch :chat {:type :scroll-line-down :lines (math/abs scroll-delta)})))))
                                                         (when (and scroll-result (tuple? scroll-result) (= :scroll-optimized (first scroll-result)))
                                                           (scroll-region-optimize (get scroll-result 1) (get scroll-result 2)))
                                                         # If we read a non-scroll event, handle it next iteration
                                                         # by pushing it back — but term has no pushback, so handle inline
                                                         (when next
                                                           (def next-type (get next :type))
                                                           (cond
                                                             (= :resize next-type)
                                                             (do (refresh-and-layout) (widget/mark-all-dirty))
                                                             # Key events → editor (capture result and handle it)
                                                             (= :key next-type)
                                                             (do
                                                               (def key-result (widget/dispatch :editor next))
                                                               (cond
                                                                 (= key-result :quit)
                                                                 (do (chat/cleanup) (set should-quit true) (break))

                                                                 (= key-result :stop)
                                                                 (chat/stop)

                                                                 (string? key-result)
                                                                 (when (not= "" key-result)
                                                                   (def cmd-result (commands/dispatch key-result))
                                                                   (if (get cmd-result :handled)
                                                                     (if (= :quit (get cmd-result :result))
                                                                       (do (chat/cleanup) (set should-quit true) (break))
                                                                       (do
                                                                         (chat/output-user key-result)
                                                                         (def r (get cmd-result :result))
                                                                         (when (and r (not= "" r))
                                                                           (each line (string/split "\n" r)
                                                                             (chat/output-info line)))
                                                                         (widget/mark-dirty :editor)))
                                                                     (chat/submit key-result)))

                                                                 (and (tuple? key-result) (= :eval (first key-result)))
                                                                 (do
                                                                   (def code (get key-result 1))
                                                                   (when (and code (not= "" code))
                                                                     (eval-janet-inline code)))

                                                                 # Scroll signals → chat widget
                                                                 (= key-result :scroll-up)
                                                                 (widget/dispatch :chat {:type :scroll-up})

                                                                 (= key-result :scroll-down)
                                                                 (widget/dispatch :chat {:type :scroll-down})

                                                                 (= key-result :scroll-line-up)
                                                                 (let [sr (widget/dispatch :chat {:type :scroll-line-up})]
                                                                   (when (and sr (tuple? sr) (= :scroll-optimized (first sr)))
                                                                     (scroll-region-optimize (get sr 1) (get sr 2))))

                                                                 (= key-result :scroll-line-down)
                                                                 (let [sr (widget/dispatch :chat {:type :scroll-line-down})]
                                                                   (when (and sr (tuple? sr) (= :scroll-optimized (first sr)))
                                                                     (scroll-region-optimize (get sr 1) (get sr 2))))

                                                                 (= key-result :rerender)
                                                                 (force-rerender))))))

                                                       # All other events → editor widget
                                                       # Batch key events for paste performance: drain all pending
                                                       # key events before rendering, like we do for scroll events.
                                                       (profile/with-span "event:key" "event" (fn []
                                                                                               # Intercept Alt+Arrow for focus navigation
                                                                                               (def key (get ev :key))
                                                                                               (def alt (get ev :alt))
                                                                                               (var focus-handled false)
                                                                                               (when alt
                                                                                                 (def direction
                                                                                                   (case key
                                                                                                     :up :up
                                                                                                     :down :down
                                                                                                     :left :left
                                                                                                     :right :right
                                                                                                     nil))
                                                                                                 (when direction
                                                                                                   (widget/focus-direction direction)
                                                                                                   (widget/mark-dirty :editor)
                                                                                                   (set focus-handled true)))

                                                                                               (when (not focus-handled)
                                                                                                 (editor/batch-begin)
                                                                                                 # Dispatch to currently focused widget (not hardcoded :editor)
                                                                                                 (def focused-widget (widget/focused))
                                                                                                 (def focused-name (when focused-widget (focused-widget :name)))
                                                                                                 (var result (when focused-name (widget/dispatch focused-name ev)))
                                                                                                 (var leftover nil)
                                                                                                 (when (nil? result)
                                                                                                   (var next-ev (term/read-event 0))
                                                                                                   (while (and next-ev (= :key (get next-ev :type)))
                                                                                                     (set result (when focused-name (widget/dispatch focused-name next-ev)))
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
                                                                                                  (do (chat/cleanup) (set should-quit true) (break))

                                                                                                  (= result :stop)
                                                                                                  (chat/stop)

                                                                                                  (string? result)
                                                                                                  (when (not= "" result)
                                                                                                    (def cmd-result (commands/dispatch result))
                                                                                                    (if (get cmd-result :handled)
                                                                                                      (if (= :quit (get cmd-result :result))
                                                                                                        (do (chat/cleanup) (set should-quit true) (break))
                                                                                                        (do
                                                                                                          (chat/output-user result)
                                                                                                          (def r (get cmd-result :result))
                                                                                                          (when (and r (not= "" r))
                                                                                                            (each line (string/split "\n" r)
                                                                                                              (chat/output-info line)))
                                                                                                          (widget/mark-dirty :editor)))
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
                                                                                                  (let [sr (widget/dispatch :chat {:type :scroll-line-up})]
                                                                                                    (when (and sr (tuple? sr) (= :scroll-optimized (first sr)))
                                                                                                      (scroll-region-optimize (get sr 1) (get sr 2))))

                                                                                                  (= result :scroll-line-down)
                                                                                                  (let [sr (widget/dispatch :chat {:type :scroll-line-down})]
                                                                                                    (when (and sr (tuple? sr) (= :scroll-optimized (first sr)))
                                                                                                      (scroll-region-optimize (get sr 1) (get sr 2))))

                                                                                                  (= result :toggle-thinking)
                                                                                                  (widget/dispatch :chat {:type :toggle-thinking})

                                                                                                  (= result :rerender)
                                                                                                  (force-rerender)))))))

      # 4. Poll RPC server (accept connections, process requests)
                                                   (when rpc-server
                                                     (rpc-srv/poll-and-dispatch rpc-server)
                                                     (rpc-srv/check-mode-change rpc-server)
                                                     (rpc-srv/flush rpc-server)
                                                     (when (rpc-srv/shutdown-requested? rpc-server)
                                                       (chat/cleanup)
                                                       (set should-quit true)
                                                       (break)))

      # 5. Update all widgets (chat drains stream, polls tools)
                                                   (profile/with-span "widget:update-all" "update" (fn [] (widget/update-all)))

      # 5b. Drain stream scroll counter (consumed but not used for scroll-region
      # optimization during streaming — the buffer-reset-dirty path handles it)
                                                   (chat/drain-stream-scroll)

      # 6. Tick widget timers
                                                   (profile/with-span "widget:tick-timers" "timer" (fn [] (widget/tick-timers)))

      # 7. Re-layout if editor height changed or layout was swapped
                                                   (def layout-swap (widget/layout-dirty?))
                                                   (when (or (not= (editor/get-height) (or ((ui/get-layout) :editor-height) 1))
                                                             layout-swap)
                                                     (widget/clear-layout-dirty)
                                                     # Clear the terminal when layout changes so stale widget
                                                     # content doesn't bleed through in uncovered areas.
                                                     (when layout-swap
                                                       (term/write "\x1b[2J"))
                                                     (refresh-and-layout)
                                                     (widget/mark-all-dirty))

      # 8. Render frame (diff-based)
                                                   (profile/with-span "render:frame" "render" (fn [] (render-frame)))))

    # Cleanup RPC server if started
     (when rpc-server
       (rpc-srv/stop rpc-server)))))

    # close defer, defn
