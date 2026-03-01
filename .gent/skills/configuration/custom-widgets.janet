# Final Working Custom Widgets for Gent
# TESTED AND CONFIRMED WORKING!

(import core/widget :as widget)
(import core/conversation :as conv)
(import widgets/editor :as editor)
(import tui)

# ── Working Clock Widget ──────────────────────────────────────

(defn create-clock-widget []
  "A live digital clock with date - updates every second"
  @{:name :clock
    :state @{}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[{:interval-ms 1000 :last-tick 0
               :callback (fn [self] (put self :dirty true))}]
    
    :handle (fn [self event] nil)
    
    :render (fn [self rect buf]
              (when (and rect (> (rect :width) 0) (> (rect :height) 0))
                # Draw blue background
                (for row 0 (rect :height)
                  (for col 0 (rect :width)
                    (tui/buffer-set-char buf (+ (rect :x) col) (+ (rect :y) row) 
                                         " " (tui/style :bg :blue))))
                
                # Draw white border
                (def blk (tui/block :title "Clock" :borders :all :border-type :rounded
                                    :border-style (tui/style :fg :white :bg :blue)))
                (tui/render blk rect buf)
                (def inner (tui/block-inner blk rect))
                
                # Show current time
                (when (> (inner :height) 0)
                  (def now (os/date))
                  (def time-str (string/format "%02d:%02d:%02d" 
                                               (now :hours) (now :minutes) (now :seconds)))
                  (def tx (+ (inner :x) (max 0 (math/floor (/ (- (inner :width) (length time-str)) 2)))))
                  (tui/buffer-set-string buf tx (inner :y) time-str 
                                         (tui/style :fg :yellow :bg :blue :bold true))
                  
                  # Show date on second line
                  (when (> (inner :height) 1)
                    (def date-str (string/format "%04d-%02d-%02d"
                                                 (now :year) (now :month) (now :month-day)))
                    (def dx (+ (inner :x) (max 0 (math/floor (/ (- (inner :width) (length date-str)) 2)))))
                    (tui/buffer-set-string buf dx (+ (inner :y) 1) date-str
                                           (tui/style :fg :cyan :bg :blue))))))})

# ── Token Counter Widget ──────────────────────────────────────

(defn create-token-widget []
  "Shows conversation stats - tokens and message count"
  @{:name :tokens
    :state @{}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[{:interval-ms 2000 :last-tick 0
               :callback (fn [self] (put self :dirty true))}]
    
    :handle (fn [self event] nil)
    
    :render (fn [self rect buf]
              (when (and rect (> (rect :width) 0) (> (rect :height) 0))
                # Green background
                (for row 0 (rect :height)
                  (for col 0 (rect :width)
                    (tui/buffer-set-char buf (+ (rect :x) col) (+ (rect :y) row)
                                         " " (tui/style :bg :green))))
                
                (def blk (tui/block :title "Stats" :borders :all :border-type :rounded
                                    :border-style (tui/style :fg :black :bg :green)))
                (tui/render blk rect buf)
                (def inner (tui/block-inner blk rect))
                
                (when (> (inner :height) 0)
                  (def tokens (conv/estimate-tokens))
                  (def msgs (conv/length))
                  
                  # Show token count
                  (def token-str (string tokens " tok"))
                  (tui/buffer-set-string buf (inner :x) (inner :y) token-str
                                         (tui/style :fg :black :bg :green :bold true))
                  
                  # Show message count
                  (when (> (inner :height) 1)
                    (def msg-str (string msgs " msg"))
                    (tui/buffer-set-string buf (inner :x) (+ (inner :y) 1) msg-str
                                           (tui/style :fg :black :bg :green)))))})

# ── System Info Widget ────────────────────────────────────────

(defn create-system-widget []
  "Shows system information - directory and uptime"
  @{:name :system
    :state @{:start-time (os/clock)}
    :rect nil
    :dirty true
    :focused false
    :tasks @[]
    :timers @[{:interval-ms 5000 :last-tick 0
               :callback (fn [self] (put self :dirty true))}]
    
    :handle (fn [self event] nil)
    
    :render (fn [self rect buf]
              (when (and rect (> (rect :width) 0) (> (rect :height) 0))
                # Purple background
                (for row 0 (rect :height)
                  (for col 0 (rect :width)
                    (tui/buffer-set-char buf (+ (rect :x) col) (+ (rect :y) row)
                                         " " (tui/style :bg :magenta))))
                
                (def blk (tui/block :title "System" :borders :all :border-type :rounded
                                    :border-style (tui/style :fg :white :bg :magenta)))
                (tui/render blk rect buf)
                (def inner (tui/block-inner blk rect))
                
                (when (> (inner :height) 0)
                  # Show current directory (shortened)
                  (def cwd (os/cwd))
                  (def short-cwd (if (> (length cwd) (- (inner :width) 2))
                                    (string "…" (string/slice cwd (- (+ 2 (inner :width)) (length cwd))))
                                    cwd))
                  (tui/buffer-set-string buf (inner :x) (inner :y) short-cwd
                                         (tui/style :fg :white :bg :magenta :bold true))
                  
                  # Show uptime
                  (when (> (inner :height) 1)
                    (def uptime (math/floor (- (os/clock) (get-in self [:state :start-time]))))
                    (def mins (math/floor (/ uptime 60)))
                    (def secs (% uptime 60))
                    (def up-str (string/format "%dm %ds" mins secs))
                    (tui/buffer-set-string buf (inner :x) (+ (inner :y) 1) up-str
                                           (tui/style :fg :white :bg :magenta)))))})

# ── Layout Configurations ─────────────────────────────────────

(defn setup-clock-layout []
  "Simple two-pane: chat + clock"
  (widget/set-layout-data
    @[{:constraint :fill
       :children [{:widget :chat :constraint 0.7}
                  {:widget :clock :constraint 0.3}]}
      {:widget :editor :constraint |(editor/get-height)}]))

(defn setup-three-pane-layout []
  "Three widgets on right side"
  (widget/set-layout-data
    @[{:constraint :fill
       :children [{:widget :chat :constraint 0.6}
                  {:widget :clock :constraint 0.15}
                  {:widget :tokens :constraint 0.15}
                  {:widget :system :constraint 0.1}]}
      {:widget :editor :constraint |(editor/get-height)}]))

(defn setup-sidebar-layout []
  "Vertical sidebar with all widgets"
  (widget/set-layout-data
    @[{:constraint :fill
       :children [{:widget :chat :constraint 0.75}
                  {:constraint 0.25
                   :children [{:widget :clock :constraint 0.4}
                              {:widget :tokens :constraint 0.3}
                              {:widget :system :constraint 0.3}]}]}
      {:widget :editor :constraint |(editor/get-height)}]))

# ── Registration Functions ────────────────────────────────────

(defn register-clock []
  (widget/register (create-clock-widget))
  (print "✓ Clock widget registered"))

(defn register-tokens []
  (widget/register (create-token-widget))
  (print "✓ Token widget registered"))

(defn register-system []
  (widget/register (create-system-widget))
  (print "✓ System widget registered"))

(defn register-all-working-widgets []
  "Register all tested, working widgets"
  (register-clock)
  (register-tokens)
  (register-system)
  (print "✓ All working widgets registered"))

# ── Easy Setup Functions ──────────────────────────────────────

(defn demo-clock []
  "Simple demo: just the clock"
  (register-clock)
  (setup-clock-layout)
  # CRITICAL: Apply layout immediately!
  (def screen-area (tui/rect 0 0 120 30))
  (widget/do-layout screen-area)
  (print "✓ Clock demo ready!"))

(defn demo-all-widgets []
  "Full demo: all widgets in three-pane layout"
  (register-all-working-widgets)
  (setup-three-pane-layout)
  # CRITICAL: Apply layout immediately!
  (def screen-area (tui/rect 0 0 120 30))
  (widget/do-layout screen-area)
  (print "✓ All widgets demo ready!"))

(print "Working widgets library loaded!")
(print "Available demos: (demo-clock) or (demo-all-widgets)")
(print "IMPORTANT: Demos auto-apply layout - widgets appear immediately!")