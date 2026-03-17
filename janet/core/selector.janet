# core/selector.janet — Generic searchable selection overlay.

(import core/fuzzy :as fuzzy)
(import core/widget :as widget)
(import tui)

# ── State ────────────────────────────────────────────────────

(var- state :idle)
(var- items @[])
(var- filtered @[])
(var- selected 0)
(var- scroll-offset 0)
(var- query "")
(var- title "Selector")
(var- empty-text "No items found.")
(var- hint-text "  ↑↓ navigate  enter select  esc close")
(var- on-submit nil)

# ── Constants ────────────────────────────────────────────────

(def- max-popup-width 80)
(def- max-visible-rows 20)

# ── Helpers ──────────────────────────────────────────────────

(defn- item-search-text [item]
  (or (get item :search-text)
      (do
        (def label (or (get item :label) (get item :id) ""))
        (def detail (get item :detail))
        (if detail
          (string label " " detail)
          label))))

(defn- format-row [item]
  (def label (or (get item :label) (get item :id) ""))
  (def detail (get item :detail))
  (def marker (if (get item :current false) " *" ""))
  (if detail
    (string label " — " detail marker)
    (string label marker)))

(defn- apply-query-filter [all-items q]
  (if (or (nil? q) (= "" q))
    all-items
    (do
      (var matches @[])
      (for i 0 (length all-items)
        (def item (get all-items i))
        (def s (fuzzy/score (item-search-text item) q))
        (when s
          (array/push matches {:index i :score s})))
      (set matches (sort-by |(get-in $ [:score :score] math/inf) matches))
      (map |(get all-items ($ :index)) matches))))

(defn- emit-content-row
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

(defn- emit-separator-row [cells popup-x popup-width border-style y]
  (array/push cells {:x popup-x :y y :ch "├" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y y :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y y :ch "┤" :style border-style}))

# ── Public API ───────────────────────────────────────────────

(defn active? [] (= state :active))

(defn reset-state []
  (set state :idle)
  (set items @[])
  (set filtered @[])
  (set selected 0)
  (set scroll-offset 0)
  (set query "")
  (set title "Selector")
  (set empty-text "No items found.")
  (set hint-text "  ↑↓ navigate  enter select  esc close")
  (set on-submit nil))

(defn open
  "Open a generic selector overlay.

   opts:
     :title string
     :items array of {:id :label :detail :search-text :current}
     :empty-text string
     :hint string
     :on-submit (fn [item])"
  [opts]
  (set items (or (get opts :items) @[]))
  (set filtered items)
  (set selected 0)
  (set scroll-offset 0)
  (set query "")
  (set title (or (get opts :title) "Selector"))
  (set empty-text (or (get opts :empty-text) "No items found."))
  (set hint-text (or (get opts :hint) "  ↑↓ navigate  enter select  esc close"))
  (set on-submit (get opts :on-submit))
  (set state :active)
  (widget/mark-dirty :chat))

(defn close []
  (when (= state :idle) (break))
  (set state :idle)
  (set on-submit nil)
  (widget/mark-dirty :chat))

(defn get-selected []
  (when (and (>= selected 0) (< selected (length filtered)))
    (get filtered selected)))

(defn get-filtered [] filtered)
(defn get-query [] query)

(defn- submit-selected []
  (def item (get-selected))
  (when item
    (def callback on-submit)
    (set state :idle)
    (set on-submit nil)
    (widget/mark-dirty :chat)
    (when callback
      (callback item))
    item))

(defn select-next []
  (def n (length filtered))
  (when (= n 0) (break))
  (set selected (mod (+ selected 1) n))
  (when (>= selected (+ scroll-offset max-visible-rows))
    (set scroll-offset (- selected max-visible-rows -1)))
  (widget/mark-dirty :chat))

(defn select-prev []
  (def n (length filtered))
  (when (= n 0) (break))
  (set selected (mod (+ selected (- n 1)) n))
  (when (< selected scroll-offset)
    (set scroll-offset selected))
  (when (>= selected (+ scroll-offset max-visible-rows))
    (set scroll-offset (- selected max-visible-rows -1)))
  (widget/mark-dirty :chat))

(defn search-insert [ch]
  (set query (string query ch))
  (set filtered (apply-query-filter items query))
  (set selected 0)
  (set scroll-offset 0)
  (widget/mark-dirty :chat))

(defn search-delete-back []
  (when (> (length query) 0)
    (set query (string/slice query 0 (- (length query) 1)))
    (set filtered (apply-query-filter items query))
    (set selected 0)
    (set scroll-offset 0)
    (widget/mark-dirty :chat)))

(defn search-clear []
  (when (not= "" query)
    (set query "")
    (set filtered items)
    (set selected 0)
    (set scroll-offset 0)
    (widget/mark-dirty :chat)))

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

    (= key :enter)
    (do (submit-selected) :consumed)

    (= key :escape)
    (if (not= "" query)
      (do (search-clear) :consumed)
      (do (close) :consumed))

    (= key :backspace)
    (do (search-delete-back) :consumed)

    (and (string? key) (= (length key) 1)
         (>= (get key 0) 0x20) (<= (get key 0) 0x7E)
         (not= key "j") (not= key "k"))
    (do (search-insert key) :consumed)

    :consumed))

(defn render-overlay
  "Render the selector overlay into a popup cell array."
  [screen-area]
  (when (not= state :active) (break nil))

  (def border-style (tui/style :fg :cyan))
  (def title-style (tui/style :fg :cyan :bold true))
  (def normal-style (tui/style))
  (def selected-style (tui/style :reversed true))
  (def hint-style (tui/style :fg :bright-black))
  (def current-style (tui/style :fg :green))

  (def popup-width (min max-popup-width (- (screen-area :width) 4)))
  (def inner-width (- popup-width 2))
  (when (<= inner-width 0) (break nil))

  (def content-rows (min (length filtered) max-visible-rows))
  (def title-text
    (if (= "" query)
      (string "  " title)
      (string "  " title " │ " query)))

  (def popup-height (+ 1 1 1 (max content-rows 1) 1 1 1))
  (def popup-x (math/floor (/ (- (screen-area :width) popup-width) 2)))
  (def popup-y (math/floor (/ (- (screen-area :height) popup-height) 2)))
  (when (or (< popup-x 0) (< popup-y 0)) (break nil))

  (def cells @[])

  (array/push cells {:x popup-x :y popup-y :ch "╭" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y popup-y :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y popup-y :ch "╮" :style border-style})

  (var y-cursor (+ popup-y 1))
  (emit-content-row cells popup-x popup-width inner-width border-style
    y-cursor title-text title-style)
  (++ y-cursor)

  (emit-separator-row cells popup-x popup-width border-style y-cursor)
  (++ y-cursor)

  (if (= 0 (length filtered))
    (do
      (emit-content-row cells popup-x popup-width inner-width border-style
        y-cursor (string "  " empty-text) hint-style)
      (++ y-cursor))
    (do
      (def start-idx scroll-offset)
      (def end-idx (min (+ start-idx content-rows) (length filtered)))
      (for i start-idx end-idx
        (def item (get filtered i))
        (def row-text (string "  " (format-row item)))
        (def trimmed (if (> (length row-text) inner-width)
                       (string/slice row-text 0 inner-width)
                       row-text))
        (def style
          (if (= i selected)
            selected-style
            (if (get item :current false)
              current-style
              normal-style)))
        (emit-content-row cells popup-x popup-width inner-width border-style
          (+ y-cursor (- i start-idx)) trimmed style))
      (+= y-cursor content-rows)))

  (emit-content-row cells popup-x popup-width inner-width border-style
    y-cursor "" normal-style)
  (++ y-cursor)

  (def trimmed-hint (if (> (length hint-text) inner-width)
                      (string/slice hint-text 0 inner-width)
                      hint-text))
  (emit-content-row cells popup-x popup-width inner-width border-style
    y-cursor trimmed-hint hint-style)
  (++ y-cursor)

  (array/push cells {:x popup-x :y y-cursor :ch "╰" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y y-cursor :ch "─" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y y-cursor :ch "╯" :style border-style})

  {:cells cells
   :width popup-width
   :height popup-height
   :x popup-x
   :y popup-y})
