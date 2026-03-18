# core/sessions-explorer.janet — Interactive session tree explorer overlay.
#
# A modal overlay that displays sessions as a tree (with fork relationships)
# and allows navigation, resuming, forking, and deletion.
# Sessions can be expanded (Tab) to show individual messages inline.
# Enter on a message forks from that point.
#
# State machine: :idle → open() → :active → close()/action → :idle

(import core/widget :as widget)
(import core/conversation :as conv)
(import core/fuzzy :as fuzzy)
(import widgets/chat :as chat)
(import tui)

# ── State ────────────────────────────────────────────────────

(var- state :idle)
(var- flat-list @[])
(var- selected 0)
(var- scroll-offset 0)
(var- query "")
(var- filtered @[])
(var- result-box nil)
(var- expanded @{})
(var- tree-cache @[])

# ── Constants ────────────────────────────────────────────────

(def- max-popup-width 80)
(def- max-visible-rows 20)

# ── Helpers ──────────────────────────────────────────────────

(defn- format-session-id
  "Shorten a session ID for display. YYYYMMDD-HHMMSS-NNNN → MM/DD HH:MM"
  [sid]
  (if (and (>= (length sid) 15) (string/has-prefix? "20" sid))
    (do
      (def parts (string/split "-" sid))
      (when (>= (length parts) 3)
        (def date-part (get parts 0))
        (def time-part (get parts 1))
        (string (string/slice date-part 4 6) "/" (string/slice date-part 6 8)
                " " (string/slice time-part 0 2) ":" (string/slice time-part 2 4))))
    sid))

(defn- format-message-preview
  "Format a single message for inline display. Returns a short string."
  [msg max-width]
  (def role (get msg :role ""))
  (def content (get msg :content ""))
  (def role-str
    (if (= role "user") "user" "asst"))
  (def preview
    (if (string? content)
      (if (string/has-prefix? "[context]" content)
        "[context]"
        content)
      # Array content — tool results or complex blocks
      (do
        (var text-found nil)
        (each block content
          (when (and (not text-found) (= "tool_result" (get block :type)))
            (set text-found "[tool results]"))
          (when (and (not text-found) (= "text" (get block :type)))
            (set text-found (get block :text "")))
          (when (and (not text-found) (= "tool_use" (get block :type)))
            (set text-found (string "[" (get block :name "") "]"))))
        (or text-found "[...]"))))
  # Single-line, replace newlines
  (def oneline (string/replace-all "\n" " " preview))
  (def prefix (string role-str ": "))
  (def avail (- max-width (length prefix)))
  (if (> (length oneline) avail)
    (string prefix (string/slice oneline 0 (max 0 (- avail 1))) "…")
    (string prefix oneline)))

(defn- flatten-tree
  "Pre-order flatten a session tree into a navigable list.
   Session entries: @{:type :session :session node :depth n :tree-prefix string}
   Message entries (for expanded sessions):
     @{:type :message :session-id sid :msg-index i :msg msg :depth n :tree-prefix string}"
  [roots]
  (def result @[])
  (defn walk [nodes depth parent-prefixes]
    (for i 0 (length nodes)
      (def node (get nodes i))
      (def is-last (= i (- (length nodes) 1)))
      # Build tree prefix from parent prefixes
      (def prefix @"")
      (each p parent-prefixes
        (buffer/push prefix p))
      (when (> depth 0)
        (buffer/push prefix (if is-last "└─ " "├─ ")))
      (array/push result
        @{:type :session
          :session node
          :depth depth
          :tree-prefix (string prefix)})
      # If this session is expanded, insert message rows
      (def msgs (get expanded (node :id)))
      (when msgs
        (def msg-prefix @"")
        (each p parent-prefixes
          (buffer/push msg-prefix p))
        (when (> depth 0)
          (buffer/push msg-prefix (if is-last "   " "│  ")))
        (def msg-prefix-str (string msg-prefix))
        (for mi 0 (length msgs)
          (def msg (get msgs mi))
          (def content (get msg :content))
          # Skip tool-result user messages (API plumbing, not human input)
          (when (or (not= "user" (get msg :role))
                    (string? content))
            (array/push result
              @{:type :message
                :session-id (node :id)
                :msg-index (+ mi 1)  # 1-indexed for fork-from-session
                :msg msg
                :depth (+ depth 1)
                :tree-prefix (string msg-prefix-str "   ")}))))
      # Build continuation prefix for children
      (def child-prefixes (array/slice parent-prefixes))
      (when (> depth 0)
        (array/push child-prefixes (if is-last "   " "│  ")))
      (when (> (length (node :children)) 0)
        (walk (node :children) (+ depth 1) child-prefixes))))
  (walk roots 0 @[])
  result)

(defn- format-row
  "Format a flat-list entry as a display string."
  [entry current-sid]
  (def entry-type (get entry :type :session))
  (if (= entry-type :message)
    # Message row
    (do
      (def mi (entry :msg-index))
      (def msg (entry :msg))
      (def prefix (entry :tree-prefix))
      (string prefix "[" mi "] " (format-message-preview msg 60)))
    # Session row
    (do
      (def s (entry :session))
      (def prefix (entry :tree-prefix))
      (def is-expanded (get expanded (s :id)))
      (def indicator (if is-expanded "▼ " "▶ "))
      (def date-str (or (format-session-id (s :id)) (s :id)))
      (def msgs (string (s :message-count) " msgs"))
      (def marker (if (= (s :id) current-sid) " *" ""))
      (string prefix indicator date-str "  " msgs marker))))

(defn- entry-search-text
  "Return expanded search text for an explorer entry.
   Includes the visible row text plus raw session IDs for exact lookup."
  [entry]
  (def entry-type (get entry :type :session))
  (if (= entry-type :message)
    (string (format-row entry "")
            " "
            (get entry :session-id "")
            " "
            (get entry :msg-index 0))
    (do
      (def s (entry :session))
      (string (format-row entry "")
              " "
              (s :id)))))

(defn- apply-query-filter
  "Filter flat-list by query string using fuzzy matching."
  [items q]
  (if (or (nil? q) (= "" q))
    items
    (do
      (var matches @[])
      (for i 0 (length items)
        (def item (get items i))
        (def s (fuzzy/score (entry-search-text item) q))
        (when s
          (array/push matches {:index i :score s})))
      (set matches (sort-by |(get-in $ [:score :score] math/inf) matches))
      (map |(get items ($ :index)) matches))))

(defn- rebuild-flat-list
  "Rebuild flat-list from cached tree and current expanded state."
  []
  (set flat-list (flatten-tree tree-cache))
  (set filtered (apply-query-filter flat-list query)))

# ── Public API ───────────────────────────────────────────────

(defn active? [] (= state :active))

(defn reset-state
  "Reset all state to idle. Useful for tests."
  []
  (set state :idle)
  (set flat-list @[])
  (set selected 0)
  (set scroll-offset 0)
  (set query "")
  (set filtered @[])
  (set result-box nil)
  (set expanded @{})
  (set tree-cache @[]))

(defn open
  "Open the sessions explorer. Loads sessions, builds tree, activates overlay."
  []
  (def sessions (conv/list-sessions-with-meta))
  (def tree (conv/build-session-tree sessions))
  (set tree-cache tree)
  (set expanded @{})
  (set flat-list (flatten-tree tree))
  (set query "")
  (set filtered flat-list)
  (set selected 0)
  (set scroll-offset 0)
  (set state :active)
  (set result-box @{:action nil :session-id nil})
  (widget/mark-dirty :chat)
  result-box)

(defn close
  "Close the explorer overlay."
  []
  (when (= state :idle) (break))
  (set state :idle)
  (widget/mark-dirty :chat))

(defn get-selected
  "Return the currently selected entry, or nil."
  []
  (when (and (>= selected 0) (< selected (length filtered)))
    (get filtered selected)))

(defn select-next
  "Move selection down (wraps)."
  []
  (def n (length filtered))
  (when (= n 0) (break))
  (set selected (mod (+ selected 1) n))
  (when (>= selected (+ scroll-offset max-visible-rows))
    (set scroll-offset (- selected max-visible-rows -1)))
  (widget/mark-dirty :chat))

(defn select-prev
  "Move selection up (wraps)."
  []
  (def n (length filtered))
  (when (= n 0) (break))
  (set selected (mod (+ selected (- n 1)) n))
  (when (< selected scroll-offset)
    (set scroll-offset selected))
  (when (>= selected (+ scroll-offset max-visible-rows))
    (set scroll-offset (- selected max-visible-rows -1)))
  (widget/mark-dirty :chat))

(defn toggle-expand
  "Toggle expand/collapse of the selected session."
  []
  (def entry (get-selected))
  (when (and entry (= :session (get entry :type)))
    (def sid ((entry :session) :id))
    (if (get expanded sid)
      # Collapse
      (put expanded sid nil)
      # Expand — load messages from history file
      (do
        (def path (string (conv/project-sessions-dir) "/" sid "/history"))
        (def msgs
          (if (os/stat path)
            (conv/load-history path)
            @[]))
        (put expanded sid msgs)))
    (rebuild-flat-list)
    # Clamp selection
    (when (>= selected (length filtered))
      (set selected (max 0 (- (length filtered) 1))))
    (widget/mark-dirty :chat)))

(defn action-resume
  "Resume the selected session, load it, and rebuild the chat UI."
  []
  (def entry (get-selected))
  (when (and entry (= :session (get entry :type)))
    (def sid ((entry :session) :id))
    (when result-box
      (put result-box :action :resume)
      (put result-box :session-id sid))
    (set state :idle)
    (conv/resume sid)
    (chat/rebuild-from-messages)
    (widget/mark-dirty :chat)
    sid))

(defn action-fork-at-message
  "Fork from a message row. Creates a new session truncated at msg-index."
  []
  (def entry (get-selected))
  (when (and entry (= :message (get entry :type)))
    (def sid (entry :session-id))
    (def msg-index (entry :msg-index))
    (def new-sid (conv/fork-from-session sid msg-index))
    (when result-box
      (put result-box :action :fork)
      (put result-box :session-id new-sid))
    (set state :idle)
    (chat/rebuild-from-messages)
    (widget/mark-dirty :chat)
    new-sid))

(defn action-fork
  "Fork from the selected session or message."
  []
  (def entry (get-selected))
  (when entry
    (if (= :message (get entry :type))
      (action-fork-at-message)
      (do
        (def sid ((entry :session) :id))
        (def new-sid (conv/fork-from-session sid))
        (when result-box
          (put result-box :action :fork)
          (put result-box :session-id new-sid))
        (set state :idle)
        (chat/rebuild-from-messages)
        (widget/mark-dirty :chat)
        new-sid))))

(defn action-delete
  "Mark selected session for deletion. Returns the session ID or nil."
  []
  (def entry (get-selected))
  (when (and entry (= :session (get entry :type)))
    (def sid ((entry :session) :id))
    (when result-box
      (put result-box :action :delete)
      (put result-box :session-id sid))
    sid))

(defn search-insert
  "Append a character to the search query."
  [ch]
  (set query (string query ch))
  (set filtered (apply-query-filter flat-list query))
  (set selected 0)
  (set scroll-offset 0)
  (widget/mark-dirty :chat))

(defn search-delete-back
  "Delete the last character from the search query."
  []
  (when (> (length query) 0)
    (set query (string/slice query 0 (- (length query) 1)))
    (set filtered (apply-query-filter flat-list query))
    (set selected 0)
    (set scroll-offset 0)
    (widget/mark-dirty :chat)))

(defn search-clear
  "Clear the search query."
  []
  (when (not= "" query)
    (set query "")
    (set filtered flat-list)
    (set selected 0)
    (set scroll-offset 0)
    (widget/mark-dirty :chat)))

(defn get-query [] query)

# ── Key handling ─────────────────────────────────────────────

(defn handle-key
  "Process a key event. Returns :consumed if handled, nil otherwise."
  [event]
  (when (not= state :active) (break nil))
  (def key (get event :key))
  (cond
    (or (= key :up) (= key "k"))
    (do (select-prev) :consumed)

    (or (= key :down) (= key "j"))
    (do (select-next) :consumed)

    (= key :tab)
    (do (toggle-expand) :consumed)

    (= key :enter)
    (do
      (def entry (get-selected))
      (when entry
        (if (= :message (get entry :type))
          (action-fork-at-message)
          (action-resume)))
      :consumed)

    (= key "f")
    (do (action-fork) :consumed)

    (= key "d")
    (do (action-delete) :consumed)

    (= key :escape)
    (if (not= "" query)
      (do (search-clear) :consumed)
      (do (close) :consumed))

    (= key :backspace)
    (do (search-delete-back) :consumed)

    # Printable character → search (except f and d which are actions)
    (and (string? key) (= (length key) 1)
         (>= (get key 0) 0x20) (<= (get key 0) 0x7E)
         (not= key "f") (not= key "d")
         (not= key "j") (not= key "k"))
    (do (search-insert key) :consumed)

    # Default: consume but ignore
    :consumed))

# ── Overlay rendering ────────────────────────────────────────

(defn- emit-content-row
  "Emit a content row with border chars."
  [cells popup-x popup-width inner-width border-style y text style]
  (array/push cells {:x popup-x :y y :ch "│" :style border-style})
  (var col 0)
  (var i 0)
  (def len (length text))
  (while (and (< col inner-width) (< i len))
    (def byte (get text i))
    (def char-len
      (cond
        (< byte 0x80) 1
        (< byte 0xE0) 2
        (< byte 0xF0) 3
        4))
    (def ch (string/slice text i (min (+ i char-len) len)))
    (array/push cells {:x (+ popup-x 1 col) :y y :ch ch :style style})
    (+= i char-len)
    (++ col))
  (while (< col inner-width)
    (array/push cells {:x (+ popup-x 1 col) :y y :ch " " :style style})
    (++ col))
  (array/push cells {:x (+ popup-x popup-width -1) :y y :ch "│" :style border-style}))

(defn- emit-separator-row
  "Emit a horizontal separator row: ├──────┤"
  [cells popup-x popup-width border-style y]
  (array/push cells {:x popup-x :y y :ch "├" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y y :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y y :ch "┤" :style border-style}))

(defn render-overlay
  "Compute the sessions explorer overlay as a cell array.
   screen-area: tui rect of the full screen.
   Returns {:cells [...] :width :height :x :y} or nil."
  [screen-area]
  (when (not= state :active) (break nil))

  (def border-style (tui/style :fg :cyan))
  (def title-style (tui/style :fg :cyan :bold true))
  (def normal-style (tui/style))
  (def selected-style (tui/style :reversed true))
  (def hint-style (tui/style :fg :bright-black))
  (def current-style (tui/style :fg :green))
  (def message-style (tui/style :fg :bright-black))

  (def current-sid (conv/get-session-id))

  (def popup-width (min max-popup-width (- (screen-area :width) 4)))
  (def inner-width (- popup-width 2))
  (when (<= inner-width 0) (break nil))

  (def content-rows (min (length filtered) max-visible-rows))
  (def title-text
    (if (= "" query)
      "  Sessions"
      (string "  Sessions │ " query)))

  # top-border + title + separator + content-rows + padding + hint + bottom-border
  (def popup-height (+ 1 1 1 (max content-rows 1) 1 1 1))

  (def popup-x (math/floor (/ (- (screen-area :width) popup-width) 2)))
  (def popup-y (math/floor (/ (- (screen-area :height) popup-height) 2)))
  (when (or (< popup-x 0) (< popup-y 0)) (break nil))

  (def cells @[])

  # ── Top border ──
  (array/push cells {:x popup-x :y popup-y :ch "╭" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y popup-y :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y popup-y :ch "╮" :style border-style})

  # ── Title row ──
  (var y-cursor (+ popup-y 1))
  (emit-content-row cells popup-x popup-width inner-width border-style
    y-cursor title-text title-style)
  (++ y-cursor)

  # ── Separator ──
  (emit-separator-row cells popup-x popup-width border-style y-cursor)
  (++ y-cursor)

  # ── Content rows ──
  (if (= 0 (length filtered))
    (do
      (emit-content-row cells popup-x popup-width inner-width border-style
        y-cursor "  No sessions found." hint-style)
      (++ y-cursor))
    (do
      (def start-idx scroll-offset)
      (def end-idx (min (+ start-idx content-rows) (length filtered)))
      (for i start-idx end-idx
        (def entry (get filtered i))
        (def is-sel (= i selected))
        (def entry-type (get entry :type :session))
        (def row-text (string "  " (format-row entry current-sid)))
        (def trimmed (if (> (length row-text) inner-width)
                       (string/slice row-text 0 inner-width)
                       row-text))
        (def style
          (if is-sel
            selected-style
            (if (= entry-type :message)
              message-style
              (if (and (= entry-type :session)
                       (= ((entry :session) :id) current-sid))
                current-style
                normal-style))))
        (emit-content-row cells popup-x popup-width inner-width border-style
          (+ y-cursor (- i start-idx)) trimmed style))
      (+= y-cursor content-rows)))

  # ── Padding row ──
  (emit-content-row cells popup-x popup-width inner-width border-style
    y-cursor "" normal-style)
  (++ y-cursor)

  # ── Hint row ──
  (def hint "  ↑↓ navigate  tab expand  enter resume/fork  esc close")
  (def trimmed-hint (if (> (length hint) inner-width)
                      (string/slice hint 0 inner-width)
                      hint))
  (emit-content-row cells popup-x popup-width inner-width border-style
    y-cursor trimmed-hint hint-style)
  (++ y-cursor)

  # ── Bottom border ──
  (array/push cells {:x popup-x :y y-cursor :ch "╰" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y y-cursor :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y y-cursor :ch "╯" :style border-style})

  {:cells cells
   :width popup-width
   :height popup-height
   :x popup-x
   :y popup-y})
