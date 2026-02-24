# core/completion.janet — Autocompletion state machine and source registry.
#
# Provides a completion popup for slash commands, skills, and file paths.
# Triggers: / for commands, /skill: for skills, @ for files.
#
# Architecture:
#   keystroke -> check-trigger -> activate -> filter -> candidates
#   Tab -> accept -> insert text + styled span
#   Up/Down -> navigate selection
#   Escape -> dismiss

(import core/commands :as commands)
(import core/skills :as skills)
(import tui)

# ── Popup rendering data ────────────────────────────────────

(def- max-popup-width 50)
(def- max-popup-height 8)

# ── State ────────────────────────────────────────────────────

(var- state :idle)
(var- trigger-kind nil)
(var- trigger-start nil)
(var- prefix "")
(var- candidates @[])
(var- selected 0)
(var- scroll-offset 0)

# ── Style ────────────────────────────────────────────────────

(var- completion-style (tui/style :fg :cyan :bold true))

(defn set-style [s] (set completion-style s))
(defn get-style [] completion-style)

# ── File cache ───────────────────────────────────────────────

(var- file-cache nil)
(var- file-cache-time 0)

(defn- git-list-files []
  (def cmd "git ls-files --cached --others --exclude-standard 2>/dev/null")
  (try
    (do
      (def result (process/exec "bash" ["-c" cmd]))
      (when (= 0 (math/round (get result :status)))
        (def stdout (get result :stdout ""))
        (if (= stdout "")
          @[]
          (string/split "\n" (string/trimr stdout)))))
    ([_] @[])))

(defn- get-file-list []
  (def now (os/clock))
  (when (or (nil? file-cache) (> (- now file-cache-time) 60))
    (set file-cache (git-list-files))
    (set file-cache-time now))
  file-cache)

(defn refresh-file-cache []
  (set file-cache nil)
  (set file-cache-time 0))

# ── Source: Commands ─────────────────────────────────────────

(defn- command-candidates [pfx]
  (def cmds (commands/list-commands))
  (def lp (string/ascii-lower pfx))
  (seq [[name desc] :in cmds
        :when (string/has-prefix? lp (string/ascii-lower name))]
    {:label (string "/" name)
     :detail desc
     :insert (string "/" name " ")}))

# ── Source: Skills ───────────────────────────────────────────

(defn- skill-candidates [pfx]
  (def skill-list (skills/list-skills))
  (def lp (string/ascii-lower pfx))
  (seq [s :in skill-list
        :when (string/has-prefix? lp (string/ascii-lower (s :name)))]
    {:label (s :name)
     :detail (s :description)
     :insert (string "/skill:" (s :name) " ")}))

# ── Source: Files ────────────────────────────────────────────

(defn- file-candidates [pfx]
  (def files (get-file-list))
  (when (nil? files) (break @[]))
  (def lp (string/ascii-lower pfx))
  (def results @[])
  (each f files
    (when (string/has-prefix? lp (string/ascii-lower f))
      (array/push results
        {:label f
         :detail ""
         :insert (string "@" f)}))
    (when (>= (length results) 50)
      (break)))
  results)

# ── Source: Commits ──────────────────────────────────────────

(var- commit-cache nil)
(var- commit-cache-time 0)

(defn- git-list-commits []
  (try
    (let [result (process/exec "git" ["log" "--oneline" "-50" "--pretty=format:%h %s"])]
      (if (= 0 (get result :status))
        (let [stdout (get result :stdout "")]
          (if (= stdout "")
            @[]
            (string/split "\n" (string/trimr stdout))))
        @[]))
    ([_] @[])))

(defn- get-commit-list []
  (def now (os/clock))
  (when (or (nil? commit-cache) (> (- now commit-cache-time) 300)) # Cache for 5 minutes
    (set commit-cache (git-list-commits))
    (set commit-cache-time now))
  commit-cache)

(defn- commit-candidates [pfx]
  (def commits (get-commit-list))
  (when (nil? commits) (break @[]))
  (def lp (string/ascii-lower pfx))
  (def results @[])
  
  (each commit commits
    (def parts (string/split " " commit 0 2))
    (when (>= (length parts) 2)
      (def hash (get parts 0))
      (def message (get parts 1))
      # Match on hash prefix or message content
      (when (or (string/has-prefix? lp (string/ascii-lower hash))
                (string/find lp (string/ascii-lower message)))
        (array/push results
          {:label hash
           :detail message
           :insert hash})))
    (when (>= (length results) 30)
      (break)))
  results)

(defn refresh-commit-cache []
  (set commit-cache nil)
  (set commit-cache-time 0))

# ── Trigger detection ────────────────────────────────────────

(defn check-trigger
  "Check if completion should activate based on content and cursor position.
   Returns {:kind :start} or nil."
  [content pt]
  (when (= pt 0) (break nil))
  (def ch (string/slice content (- pt 1) pt))
  (cond
    (= ch "@")
    {:kind :file :start (- pt 1)}

    (and (= ch "/")
         (or (= pt 1)
             (let [prev (get content (- pt 2))]
               (or (= prev (chr " ")) (= prev (chr "\n"))))))
    {:kind :command :start (- pt 1)}
    
    (= ch "#")
    {:kind :commit :start (- pt 1)}

    nil))

# ── State management ────────────────────────────────────────

(defn active? []
  (= state :active))

(defn activate
  "Activate completion with a given trigger kind and start position."
  [kind start]
  (set state :active)
  (set trigger-kind kind)
  (set trigger-start start)
  (set prefix "")
  (set candidates @[])
  (set selected 0)
  (set scroll-offset 0))

(defn dismiss []
  (set state :idle)
  (set trigger-kind nil)
  (set trigger-start nil)
  (set prefix "")
  (set candidates @[])
  (set selected 0)
  (set scroll-offset 0))

(defn get-trigger-start [] trigger-start)
(defn get-trigger-kind [] trigger-kind)
(defn get-candidates [] candidates)
(defn get-selected [] selected)
(defn get-prefix [] prefix)
(defn get-scroll-offset [] scroll-offset)

# ── Filtering ────────────────────────────────────────────────

(defn filter-candidates
  "Update candidates based on current editor content. Returns candidate count.
   content: full editor text, pt: cursor byte offset."
  [content pt]
  (when (not= state :active) (break 0))

  (def text-after-trigger
    (if (< trigger-start pt)
      (string/slice content trigger-start pt)
      ""))

  (set prefix text-after-trigger)

  (def new-candidates
    (case trigger-kind
      :command
      (do
        (def after-slash
          (if (> (length text-after-trigger) 0)
            (string/slice text-after-trigger 1)
            ""))
        (if (string/has-prefix? "skill:" after-slash)
          (let [skill-pfx (string/slice after-slash 6)]
            (skill-candidates skill-pfx))
          (command-candidates after-slash)))

      :file
      (let [after-at (if (> (length text-after-trigger) 0)
                       (string/slice text-after-trigger 1)
                       "")]
        (file-candidates after-at))
        
      :commit
      (let [after-hash (if (> (length text-after-trigger) 0)
                         (string/slice text-after-trigger 1)
                         "")]
        (commit-candidates after-hash))

      @[]))

  (set candidates new-candidates)
  (set scroll-offset 0)
  (when (>= selected (length candidates))
    (set selected (max 0 (- (length candidates) 1))))
  (length candidates))

# ── Navigation ───────────────────────────────────────────────

(defn- ensure-selected-visible []
  "Adjust scroll-offset to ensure the selected item is visible."
  (def visible-count (min (length candidates) max-popup-height))
  (cond
    # Selected item is above the visible window
    (< selected scroll-offset)
    (set scroll-offset selected)
    
    # Selected item is below the visible window
    (>= selected (+ scroll-offset visible-count))
    (set scroll-offset (- selected visible-count -1))))

(defn select-next []
  (when (> (length candidates) 0)
    (if (< selected (- (length candidates) 1))
      (set selected (+ selected 1))
      (set selected 0)) # Wrap to beginning
    (ensure-selected-visible)))

(defn select-prev []
  (when (> (length candidates) 0)
    (if (> selected 0)
      (set selected (- selected 1))
      (set selected (- (length candidates) 1))) # Wrap to end
    (ensure-selected-visible)))

# ── Accept ───────────────────────────────────────────────────

(defn accept
  "Accept the currently selected candidate.
   Returns {:insert text :start trigger-start :end pt} or nil."
  [pt]
  (when (not= state :active) (break nil))
  (when (empty? candidates) (break nil))
  (def candidate (get candidates selected))
  (def result {:insert (candidate :insert)
               :start trigger-start
               :end pt})
  (dismiss)
  result)

# ── Popup rendering data ────────────────────────────────────

(def- max-popup-width 50)
(def- max-popup-height 8)

(defn render-popup
  "Compute popup rendering data.
   cursor-row/cursor-col: 1-indexed screen position of cursor.
   screen-area: tui rect of the full screen.
   Returns {:cells [{:x :y :ch :style}] :width :height :x :y} or nil."
  [cursor-row cursor-col screen-area]
  (when (not= state :active) (break nil))
  (when (empty? candidates) (break nil))

  (def visible-count (min (length candidates) max-popup-height))
  (def start-idx scroll-offset)
  (def end-idx (min (+ start-idx visible-count) (length candidates)))

  (var max-label 0)
  (var max-detail 0)
  (for i start-idx end-idx
    (def c (get candidates i))
    (set max-label (max max-label (length (c :label))))
    (set max-detail (max max-detail (length (c :detail)))))

  (def inner-width (min (+ max-label 2 max-detail 2) (- max-popup-width 2)))
  (def popup-width (+ inner-width 2))
  (def popup-height (+ visible-count 2))

  (def popup-x (max 0 (min (- cursor-col 1) (- (screen-area :width) popup-width))))
  (def popup-y
    (if (>= (- cursor-row 1) popup-height)
      (- cursor-row 1 popup-height)
      cursor-row))

  (def cells @[])
  (def normal-style (tui/style :fg :white))
  (def selected-style (tui/style :reversed true))
  (def border-style (tui/style :fg :bright-black))

  # Top border
  (array/push cells {:x popup-x :y popup-y :ch "\xE2\x94\x8C" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y popup-y :ch "\xE2\x94\x80" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y popup-y :ch "\xE2\x94\x90" :style border-style})

  # Content rows
  (for row 0 visible-count
    (def candidate-idx (+ start-idx row))
    (when (>= candidate-idx (length candidates)) (break))
    
    (def y (+ popup-y 1 row))
    (def c (get candidates candidate-idx))
    (def is-selected (= candidate-idx selected))
    (def row-style (if is-selected selected-style normal-style))
    (def indicator (if is-selected ">" " "))

    (array/push cells {:x popup-x :y y :ch "\xE2\x94\x82" :style border-style})

    (def label-str (c :label))
    (def detail-str (c :detail))
    (def padded-label (string indicator label-str))
    (def content-str
      (if (> (length detail-str) 0)
        (let [label-space (- (+ max-label 2) (length label-str))
              pad (string/repeat " " (max 1 label-space))]
          (string padded-label pad detail-str))
        padded-label))

    (def display-str (if (> (length content-str) inner-width)
                       (string/slice content-str 0 inner-width)
                       content-str))

    (for col 0 inner-width
      (def ch (if (< col (length display-str))
                (string/slice display-str col (+ col 1))
                " "))
      (array/push cells {:x (+ popup-x 1 col) :y y :ch ch :style row-style}))

    (array/push cells {:x (+ popup-x popup-width -1) :y y :ch "\xE2\x94\x82" :style border-style}))

  # Bottom border
  (def bottom-y (+ popup-y visible-count 1))
  (array/push cells {:x popup-x :y bottom-y :ch "\xE2\x94\x94" :style border-style})
  (for col 1 (- popup-width 1)
    (array/push cells {:x (+ popup-x col) :y bottom-y :ch "\xE2\x94\x80" :style border-style}))
  (array/push cells {:x (+ popup-x popup-width -1) :y bottom-y :ch "\xE2\x94\x98" :style border-style})

  {:cells cells
   :width popup-width
   :height popup-height
   :x popup-x
   :y popup-y})
