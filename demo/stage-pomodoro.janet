# Stage script for the pomodoro widget demo.
#
# Flow:
#   1. User asks to add a pomodoro timer widget
#   2. LLM thinks (~1s), then streams eval_janet arguments (~1s)
#   3. Tool executes, widget appears, layout shifts
#   4. LLM confirms with streaming text

(import core/stage :as stage)

# ── Helpers ──────────────────────────────────────────────────

(defn sse [data] (string "data: " (json/encode data)))

(defn chunk-string [s n]
  (def result @[])
  (var i 0)
  (while (< i (length s))
    (def end (min (+ i n) (length s)))
    (array/push result (string/slice s i end))
    (set i end))
  result)

# ── Widget code (what eval_janet will run) ───────────────────

(def widget-code
  (string
    "(import core/widget :as widget)\n"
    "(import tui)\n"
    "(import widgets/editor :as editor)\n"
    "\n"
    "(widget/register\n"
    "  @{:name :pomodoro\n"
    "    :state @{:start (os/clock) :total (* 25 60)}\n"
    "    :rect nil\n"
    "    :dirty true\n"
    "    :focused false\n"
    "    :focusable false\n"
    "    :tasks @[]\n"
    "    :timers @[{:interval-ms 1000 :last-tick 0\n"
    "               :callback (fn [self] (put self :dirty true))}]\n"
    "    :handle (fn [self event] nil)\n"
    "    :render\n"
    "    (fn [self rect buf]\n"
    "      (when (or (nil? rect) (<= (rect :width) 0) (<= (rect :height) 0)) (break))\n"
    "      (def blk (tui/block :title \"Pomodoro\"\n"
    "                           :borders :all\n"
    "                           :border-type :rounded\n"
    "                           :border-style (tui/style :fg (tui/rgb 255 99 71))))\n"
    "      (tui/render blk rect buf)\n"
    "      (def inner (tui/block-inner blk rect))\n"
    "      (when (> (inner :height) 0)\n"
    "        (def elapsed (- (os/clock) (get-in self [:state :start])))\n"
    "        (def remaining (max 0 (math/floor (- (get-in self [:state :total]) elapsed))))\n"
    "        (def mins (math/floor (/ remaining 60)))\n"
    "        (def secs (% remaining 60))\n"
    "        (def label (string/format \"%02d:%02d \" mins secs))\n"
    "        (def label-len (length label))\n"
    "        (def bar-width (max 0 (- (inner :width) label-len)))\n"
    "        (def ratio (max 0 (min 1 (- 1.0 (/ elapsed (get-in self [:state :total]))))))\n"
    "        (def filled (math/round (* ratio bar-width)))\n"
    "        (tui/buffer-set-string buf (inner :x) (inner :y) label\n"
    "          (tui/style :fg (tui/rgb 255 99 71) :bold true))\n"
    "        (for i 0 bar-width\n"
    "          (if (< i filled)\n"
    "            (tui/buffer-set-char buf (+ (inner :x) label-len i) (inner :y) \"\xE2\x96\x88\"\n"
    "              (tui/style :fg (tui/rgb 255 99 71)))\n"
    "            (tui/buffer-set-char buf (+ (inner :x) label-len i) (inner :y) \"\xE2\x96\x91\"\n"
    "              (tui/style :fg (tui/color-indexed 240)))))))})\n"
    "\n"
    "(widget/set-layout-data\n"
    "  @[{:widget :pomodoro :constraint 3}\n"
    "    {:constraint :fill\n"
    "     :children [{:widget :chat :constraint :fill}]}\n"
    "    {:widget :editor :constraint |(editor/get-height)}])"))

# ── Response 1: thinking + tool call (custom SSE) ───────────

(def thinking-text
  (string
    "I'll create a pomodoro timer widget with a countdown display "
    "and progress bar. I need to register it with the widget system "
    "and update the layout to place it at the top of the UI."))

(def tool-input-json (json/encode @{:code widget-code}))
(def thinking-chunks (chunk-string thinking-text 12))
(def json-chunks (chunk-string tool-input-json 100))

(def gen
  (stage/custom
    (fn [conv]
      (def lines @[])
      # message start
      (array/push lines
        (sse @{:type "message_start"
               :message @{:id "msg_stage" :type "message"
                          :role "assistant" :content @[]
                          :model "stage" :stop_reason nil}}))
      # thinking block
      (array/push lines
        (sse @{:type "content_block_start" :index 0
               :content_block @{:type "thinking" :thinking ""}}))
      (each chunk thinking-chunks
        (array/push lines
          (sse @{:type "content_block_delta" :index 0
                 :delta @{:type "thinking_delta" :thinking chunk}})))
      (array/push lines
        (sse @{:type "content_block_stop" :index 0}))
      # tool_use block
      (array/push lines
        (sse @{:type "content_block_start" :index 1
               :content_block @{:type "tool_use"
                                :id "toolu_eval_01"
                                :name "eval_janet"
                                :input @{}}}))
      (each chunk json-chunks
        (array/push lines
          (sse @{:type "content_block_delta" :index 1
                 :delta @{:type "input_json_delta"
                          :partial_json chunk}})))
      (array/push lines
        (sse @{:type "content_block_stop" :index 1}))
      # message end
      (array/push lines
        (sse @{:type "message_delta"
               :delta @{:stop_reason "tool_use"}}))
      (array/push lines
        (sse @{:type "message_stop"}))
      (array/push lines "data: [DONE]")
      lines)))

# ~33 lines total: 15 thinking + 14 tool + 4 overhead
# 0.06s/line → ~1s thinking + ~1s tool streaming
(put gen :delay 0.06)
(stage/respond gen)

# ── Response 2: streaming confirmation ───────────────────────

(stage/respond
  (stage/text-stream
    (string
      "I've added a pomodoro timer widget at the top of your UI.\n"
      "The layout updated live. No restart needed.")
    :token-delay 0.020))
