# widgets/filepicker.janet — Configurable list picker widget.
#
# A reusable widget that displays a list of items and acts on selection.
# The source of items, the title, and the Enter action are all configurable.
#
# Usage:
#   (import widgets/filepicker :as fp)
#
#   # Default: list files in cwd
#   (fp/create)
#
#   # Git status picker
#   (fp/create :name :git-status :title "Git Status"
#              :source "git status --short"
#              :on-enter (fn [item] (print item)))
#
#   # Function source
#   (fp/create :name :recent :title "Recent"
#              :source (fn [] @["a.janet" "b.janet"]))

(import core/widget :as widget)
(import tui)

(defn- resolve-source
  "Run source to get list of items. String = shell command, function = call it."
  [source]
  (cond
    (string? source)
    (let [result (process/exec "bash" ["-c" source])]
      (if (and result (= 0 (get result :status)))
        (filter |(not= "" $) (string/split "\n" (get result :stdout "")))
        @[]))

    (function? source)
    (try (source) ([_] @[]))

    # fallback
    @[]))

(defn- default-source
  "Default source: list non-hidden files in cwd, sorted."
  []
  (def entries (try (os/dir ".") ([_] @[])))
  (sort (filter |(not (string/has-prefix? "." $)) entries)))

(defn- default-on-enter
  "Default enter handler: publish :file-opened event."
  [item]
  (widget/publish :file-opened
    {:path item :content (try (slurp item) ([_] nil))}))

(defn create
  "Create a configurable list picker widget.
   Options (all keyword args):
     :name       keyword — widget name (default :filepicker)
     :title      string  — border title (default \"Files\")
     :source     string|fn — shell command or function returning item array
     :on-enter   fn      — (fn [selected-item] ...) called on Enter
     :refresh-ms int     — refresh interval in ms (default 5000)"
  [&named name title source on-enter refresh-ms]
  (default name :filepicker)
  (default title "Files")
  (default source default-source)
  (default on-enter default-on-enter)
  (default refresh-ms 5000)
  @{:name name
    :state @{:files (resolve-source source) :selected 0 :scroll-offset 0
             :source source :on-enter on-enter :title title}
    :rect nil
    :dirty true
    :focused false
    :focusable true
    :tasks @[]
    :timers @[{:interval-ms refresh-ms :last-tick 0
               :callback (fn [self]
                           (def st (self :state))
                           (put st :files (resolve-source (st :source)))
                           (put self :dirty true))}]

    :handle (fn [self event]
              (def key (get event :key))
              (def st (self :state))
              (def files (st :files))
              (def n (length files))
              (when (= n 0) (break nil))

              (cond
                (= key :up)
                (do
                  (put st :selected (mod (+ (st :selected) (- n 1)) n))
                  (put self :dirty true)
                  (when (self :rect)
                    (def inner-h (- ((self :rect) :height) 2))
                    (when (> inner-h 0)
                      (if (< (st :selected) (st :scroll-offset))
                        (put st :scroll-offset (st :selected))
                        (when (>= (st :selected) (+ (st :scroll-offset) inner-h))
                          (put st :scroll-offset (- (st :selected) inner-h -1))))))
                  nil)

                (= key :down)
                (do
                  (put st :selected (mod (+ (st :selected) 1) n))
                  (put self :dirty true)
                  (when (self :rect)
                    (def inner-h (- ((self :rect) :height) 2))
                    (when (> inner-h 0)
                      (if (>= (st :selected) (+ (st :scroll-offset) inner-h))
                        (put st :scroll-offset (- (st :selected) inner-h -1))
                        (when (< (st :selected) (st :scroll-offset))
                          (put st :scroll-offset (st :selected))))))
                  nil)

                (= key :enter)
                (do
                  (def selected-item (get files (st :selected)))
                  (when selected-item
                    ((st :on-enter) selected-item))
                  nil)

                # Default: unhandled
                nil))

    :render (fn [self rect buf]
              (when (or (nil? rect) (<= (rect :width) 0) (<= (rect :height) 0)) (break))
              (def st (self :state))
              (def border-color
                (if (self :focused)
                  (tui/color-indexed 75)
                  (tui/color-indexed 240)))
              (def blk (tui/block :title (st :title) :borders :all :border-type :rounded
                                   :border-style (tui/style :fg border-color)
                                   :padding (tui/padding 1 1 0 0)))
              (tui/render blk rect buf)
              (def inner (tui/block-inner blk rect))
              (when (or (<= (inner :height) 0) (<= (inner :width) 0)) (break))

              (def files (st :files))
              (def selected (st :selected))
              (def scroll (st :scroll-offset))
              (def visible-h (inner :height))

              (for i 0 visible-h
                (def file-idx (+ scroll i))
                (when (< file-idx (length files))
                  (def item-name (get files file-idx))
                  (def truncated
                    (if (> (length item-name) (inner :width))
                      (string (string/slice item-name 0 (- (inner :width) 1)) "…")
                      item-name))
                  (def style
                    (if (= file-idx selected)
                      (tui/style :fg :black :bg :white)
                      (tui/style :fg (tui/color-indexed 250))))
                  (tui/buffer-set-string buf (inner :x) (+ (inner :y) i) truncated style))))})

(defn register! []
  (widget/register (create)))
