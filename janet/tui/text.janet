# tui/text.janet — Text primitives: spans, lines, and the text widget.
#
# Modeled after ratatui's Span → Line → Text hierarchy.
#   span: a styled fragment of text
#   line: a horizontal sequence of spans
#   text: a vertical sequence of lines (widget)
#
# Usage:
#   (def t (text "Hello, World!" :style (style :fg :green :bold true)))
#   (render t area buf)
#
#   # Rich text with multiple styled spans:
#   (def t (text
#     (line (span "Status: " (style :fg :white))
#           (span "OK" (style :fg :green :bold true)))
#     (line (span "Uptime: " (style :fg :white))
#           (span "42s" (style :fg :yellow)))))

(use ./rect)
(use ./style)
(use ./buffer)

# ── Inline ANSI rendering ──────────────────────────────────────
#
# For streaming/scroll-based UIs, you often need a styled string
# (not a buffer-based render). These convert spans/lines to ANSI.

(defn span->str
  "Convert a span to an inline ANSI string."
  [s]
  (def sgr (style->sgr (s :style)))
  (if (= sgr "")
    (s :text)
    (string sgr (s :text) "\x1b[0m")))

(defn line->str
  "Convert a line (sequence of spans) to an inline ANSI string.
   Each span resets before applying its own style, so styles don't bleed."
  [ln]
  (def parts @[])
  (var need-reset false)
  (each s (ln :spans)
    (def sgr (style->sgr (s :style)))
    (if (not= sgr "")
      (do
        (when need-reset (array/push parts "\x1b[0m"))
        (array/push parts sgr)
        (array/push parts (s :text))
        (set need-reset true))
      (do
        (when need-reset
          (array/push parts "\x1b[0m")
          (set need-reset false))
        (array/push parts (s :text)))))
  (when need-reset (array/push parts "\x1b[0m"))
  (string ;parts))

# ── Span ───────────────────────────────────────────────────────

(defn span
  "A styled text fragment. Style is optional."
  [content &opt st]
  (default st style-default)
  {:type :span :text content :style st})

(defn span-width
  "Visual width of a span (byte length; no wide-char support yet)."
  [s]
  (length (s :text)))

# ── Line ───────────────────────────────────────────────────────

(defn line
  "A horizontal sequence of spans."
  [& spans]
  {:type :line :spans (array ;spans)})

(defn line-width
  "Total visual width of a line."
  [ln]
  (var w 0)
  (each s (ln :spans) (+= w (span-width s)))
  w)

(defn- render-line
  "Render a single line into the buffer at row y, starting at x.
   Clips to the given max-width."
  [ln x y max-width buf]
  (var col x)
  (def limit (+ x max-width))
  (each s (ln :spans)
    (when (>= col limit) (break))
    (def text (s :text))
    (def st (s :style))
    (each byte text
      (when (>= col limit) (break))
      (buffer-set-char buf col y (string/from-bytes byte) st)
      (++ col))))

# ── Text widget ────────────────────────────────────────────────

(defn- coerce-to-line
  "Convert a value to a line: strings become a single span, lines pass through."
  [v &opt st]
  (cond
    (string? v) (line (span v (or st style-default)))
    (and (table? v) (= (v :type) :span)) (line v)
    (and (table? v) (= (v :type) :line)) v
    (and (struct? v) (= (v :type) :span)) (line v)
    (and (struct? v) (= (v :type) :line)) v
    (line (span (string v)))))

(defn text
  "Create a text widget from strings, lines, or spans.
   Strings with newlines are split into multiple lines.
   Pass :style to set a default style for plain strings."
  [& args]
  (var items @[])
  (var st nil)
  # Parse :style keyword arg from the end
  (def flat-args (array ;args))
  (when (and (>= (length flat-args) 2)
             (= (get flat-args (- (length flat-args) 2)) :style))
    (set st (last flat-args))
    (array/pop flat-args)
    (array/pop flat-args))
  # Build lines
  (each arg flat-args
    (if (string? arg)
      (each part (string/split "\n" arg)
        (array/push items (coerce-to-line part st)))
      (array/push items (coerce-to-line arg st))))
  {:type :text
   :lines items
   :render (fn [self area buf]
             (def lines (self :lines))
             (for i 0 (min (length lines) (area :height))
               (render-line (get lines i)
                            (area :x) (+ (area :y) i)
                            (area :width) buf)))})
