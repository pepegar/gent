# widgets/token-gauge.janet — Token usage gauge widget.
#
# Shows estimated token count as a visual gauge bar.
# Register with: (import widgets/token-gauge) then (token-gauge/register!)

(import core/widget :as widget)
(import core/conversation :as conv)
(import tui)

(var- max-tokens 200000)  # Claude's context window

(defn set-max-tokens [n] (set max-tokens n))

(defn create []
  @{:name :token-gauge
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
      (def blk (tui/block :title "Tokens" :borders :all :border-type :rounded
                           :border-style (tui/style :fg (tui/color-indexed 240))))
      (tui/render blk rect buf)
      (def inner (tui/block-inner blk rect))
      (when (> (inner :height) 0)
        (def tokens (conv/estimate-tokens))
        (def ratio (min 1.0 (/ tokens max-tokens)))
        (def bar-width (max 0 (- (inner :width) 0)))
        (def filled (math/round (* ratio bar-width)))

        # Color: green → yellow → red
        (def color
          (cond
            (< ratio 0.5) :green
            (< ratio 0.8) :yellow
            :red))

        # Draw gauge bar
        (for i 0 bar-width
          (if (< i filled)
            (tui/buffer-set-char buf (+ (inner :x) i) (inner :y) "█"
              (tui/style :fg color))
            (tui/buffer-set-char buf (+ (inner :x) i) (inner :y) "░"
              (tui/style :fg (tui/color-indexed 240)))))

        # Draw count below if space
        (when (> (inner :height) 1)
          (def text (string/format "%d / %dk" tokens (math/round (/ max-tokens 1000))))
          (tui/buffer-set-string buf (inner :x) (+ (inner :y) 1) text
            (tui/style :fg (tui/color-indexed 250))))))})

(defn register! []
  (widget/register (create)))
