# core/scenario.janet — Scenario DSL for scripted TUI interactions.
#
# Provides actions (tick, submit, scroll, type-text), assertions,
# and a reactor driver for stage mode scenarios.
#
# Usage:
#   (import core/scenario :as sc)
#   (sc/submit "Hello")
#   (sc/tick-until-idle)
#   (sc/assert-mode :idle)

(import core/widget :as widget)
(import widgets/chat :as chat)
(import tui)

# ── Reactor driver ────────────────────────────────────────────

(defn tick [&opt n]
  "Drive the reactor for n ticks (default 1). Updates all widgets, ticks timers."
  (default n 1)
  (for _ 0 n
    (widget/update-all)
    (widget/tick-timers)))

(defn tick-until-idle [&opt max-ticks]
  "Drive the reactor until the chat is idle. Returns tick count."
  (default max-ticks 500)
  (var ticks 0)
  (while (and (chat/active?) (< ticks max-ticks))
    (tick)
    (++ ticks))
  ticks)

(defn tick-until [pred &opt max-ticks]
  "Drive the reactor until pred returns truthy. Returns tick count."
  (default max-ticks 500)
  (var ticks 0)
  (while (and (not (pred)) (< ticks max-ticks))
    (tick)
    (++ ticks))
  ticks)

# ── Actions ───────────────────────────────────────────────────

(defn submit [text]
  "Submit text to the chat."
  (chat/submit text))

(defn scroll [direction &opt n]
  "Scroll the chat. direction: :up or :down, n: lines (default 1)."
  (default n 1)
  (for _ 0 n
    (widget/dispatch :chat
      {:type (if (= direction :up) :scroll-line-up :scroll-line-down)})))

(defn scroll-page [direction]
  "Page scroll. direction: :up or :down."
  (widget/dispatch :chat
    {:type (if (= direction :up) :scroll-up :scroll-down)}))

(defn type-text [text]
  "Inject text as key events to the editor widget."
  (each byte text
    (widget/dispatch :editor
      {:type :key :key (string/from-bytes byte)})))

(defn resize [cols rows]
  "Set terminal dimensions and re-layout."
  (widget/do-layout (tui/rect 0 0 cols rows)))

# ── Scrollback helpers ────────────────────────────────────────

(defn scrollback-texts []
  "Extract text from all scrollback lines."
  (seq [line :in (chat/get-scrollback)]
    (if (line :spans)
      (string ;(map |($ :text) (line :spans)))
      (or (line :text) ""))))

(defn find-in-scrollback [needle]
  "Return true if any scrollback line contains the needle text."
  (truthy?
    (find |(string/find needle $) (scrollback-texts))))

# ── Assertions ────────────────────────────────────────────────

(defn assert-mode [expected]
  "Assert chat mode is the expected value."
  (def actual (chat/get-mode))
  (unless (= actual expected)
    (error (string "expected mode " expected " but got " actual))))

(defn assert-visible [text]
  "Assert that text appears somewhere in the scrollback."
  (unless (find-in-scrollback text)
    (error (string "expected to find '" text "' in scrollback"))))

(defn assert-not-visible [text]
  "Assert text does NOT appear in scrollback."
  (when (find-in-scrollback text)
    (error (string "did not expect to find '" text "' in scrollback"))))

(defn assert-scroll-offset [expected]
  "Assert the scroll offset."
  (def actual (chat/get-scroll-offset))
  (unless (= actual expected)
    (error (string "expected scroll-offset " expected " but got " actual))))

(defn assert-truthy [val]
  "Assert that val is truthy."
  (unless val
    (error "expected truthy value but got falsy")))

(defn assert= [actual expected]
  "Assert two values are equal."
  (unless (= actual expected)
    (error (string "expected " expected " but got " actual))))

# ── Screenshots ───────────────────────────────────────────────

(defn screenshot [&opt path]
  "Render the chat widget into a buffer and return plain text rows.
   If path is given, also write to file."
  (def chat-w (widget/get-widget :chat))
  (when (nil? chat-w) (error "no chat widget registered"))
  (def rect (chat-w :rect))
  (when (nil? rect) (error "chat widget has no rect"))
  (def buf (tui/buffer rect))
  ((chat-w :render) chat-w rect buf)
  (def rows (tui/buffer-to-plain-rows buf))
  (when path (spit path (string/join rows "\n")))
  rows)
