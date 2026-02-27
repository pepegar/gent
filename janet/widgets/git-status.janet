# widgets/git-status.janet — Git branch + dirty files widget.
#
# Optional sidebar widget that shows current branch and modified files.
# Register with: (import widgets/git-status) then (git-status/register!)

(import core/widget :as widget)
(import tui)

(var- cached-branch "")
(var- cached-dirty @[])
(var- cached-loading false)

(defn- parse-git-status [output]
  "Parse `git status --porcelain -b` output."
  (def lines (string/split "\n" output))
  (var branch "")
  (def dirty @[])
  (each line lines
    (when (> (length line) 0)
      (if (string/has-prefix? "##" line)
        (do
          (def rest (string/slice line 3))
          (def dots (string/find "..." rest))
          (set branch (if dots (string/slice rest 0 dots) rest)))
        (array/push dirty (string/slice line 3)))))
  {:branch branch :dirty dirty})

(defn- refresh-git [self]
  "Refresh git status (called by timer)."
  (set cached-loading true)
  (put self :dirty true)
  (try
    (do
      (def result (process/exec "git" ["status" "--porcelain" "-b"]))
      (when (= 0 (get result :status))
        (def parsed (parse-git-status (get result :stdout "")))
        (set cached-branch (parsed :branch))
        (set cached-dirty (parsed :dirty))))
    ([_] nil))
  (set cached-loading false)
  (put self :dirty true))

(defn create
  "Create a git status widget. Refreshes every 5 seconds."
  []
  @{:name :git-status
    :state @{}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[@{:interval-ms 5000 :last-tick 0
                :callback (fn [self] (refresh-git self))}]

    :handle (fn [self event] nil)

    :render (fn [self rect buf]
             (when (or (nil? rect) (<= (rect :width) 0) (<= (rect :height) 0)) (break))

      # Draw border
             (def blk (tui/block :title "Git" :borders :all :border-type :rounded
                                  :border-style (tui/style :fg (tui/color-indexed 240))))
             (tui/render blk rect buf)
             (def inner (tui/block-inner blk rect))
             (when (> (inner :height) 0)
               # Branch line
               (def branch-text (string "⎇ " (if (= "" cached-branch) "..." cached-branch)))
               (tui/buffer-set-string buf (inner :x) (inner :y) branch-text
                 (tui/style :fg :cyan :bold true))

               # Dirty files
               (for i 0 (min (length cached-dirty) (- (inner :height) 1))
                 (def file (get cached-dirty i))
                 (tui/buffer-set-string buf (inner :x) (+ (inner :y) 1 i) file
                   (tui/style :fg :yellow)))))})

(defn register!
  "Create and register the git status widget."
  []
  (widget/register (create)))
