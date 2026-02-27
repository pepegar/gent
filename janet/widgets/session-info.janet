# widgets/session-info.janet — Session info widget.
#
# Displays session ID, message count, and model info.
# Register with: (import widgets/session-info) then (session-info/register!)

(import core/widget :as widget)
(import core/conversation :as conv)
(import tui)

(defn create []
  @{:name :session-info
    :state @{}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[{:interval-ms 2000 :last-tick 0
               :callback (fn [self] (put self :dirty true))}]

    :handle (fn [self event] nil)

    :render (fn [self rect buf]
             (when (or (nil? rect) (<= (rect :width) 0) (<= (rect :height) 0)) (break))
             (def blk (tui/block :title "Session" :borders :all :border-type :rounded
                                  :border-style (tui/style :fg (tui/color-indexed 240))))
             (tui/render blk rect buf)
             (def inner (tui/block-inner blk rect))
             (when (> (inner :height) 0)
               (def sid (conv/get-session-id))
               (def msgs (conv/length))
               (def tokens (conv/estimate-tokens))

               (tui/buffer-set-string buf (inner :x) (inner :y)
                 (string "ID: " (or sid "—"))
                 (tui/style :fg :cyan))

               (when (> (inner :height) 1)
                 (tui/buffer-set-string buf (inner :x) (+ (inner :y) 1)
                   (string "Messages: " msgs)
                   (tui/style :fg (tui/color-indexed 250))))

               (when (> (inner :height) 2)
                 (tui/buffer-set-string buf (inner :x) (+ (inner :y) 2)
                   (string "≈ " tokens " tokens")
                   (tui/style :fg (tui/color-indexed 250))))))})

(defn register! []
  (widget/register (create)))
