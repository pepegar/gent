# tui/markdown.janet — Streaming markdown to ANSI renderer.

(use ./text)
(use ./style)
(use ./buffer)

# Style definitions
(def- styles
  {:h1 (style :fg :bright-white :bold true)
   :h2 (style :fg :bright-white :bold true)
   :h3 (style :fg :white :bold true)
   :h4 (style :fg :white :bold true)
   :h5 (style :fg :white)
   :h6 (style :fg :white)
   :bold (style :bold true)
   :italic (style :italic true)
   :code (style :fg :cyan :bg :bright-black)
   :link (style :fg :blue :underline true)
   :list-marker (style :fg :yellow)
   :code-block (style :fg :cyan :bg :bright-black)})

# ── Complete markdown parsing (non-streaming) ──────────────────

(defn markdown->lines [md-text]
  "Convert markdown text to a sequence of styled lines"
  (def lines @[])
  (def raw-lines (string/split "\n" md-text))

  (each raw-line raw-lines
    (def trimmed (string/trim raw-line))

    (cond
      # Empty line
      (= trimmed "")
      (array/push lines (line (span "" style-default)))

      # Header (starts with #)
      (string/has-prefix? "#" trimmed)
      (let [space-pos (string/find " " trimmed)
            level (if space-pos space-pos (length trimmed))
            level (min 6 level)
            text (if space-pos (string/trim (string/slice trimmed level)) trimmed)
            header-style (get styles (keyword "h" (string level)))]
        (array/push lines (line (span text header-style))))

      # List item (starts with -, *, +)
      (or (string/has-prefix? "- " trimmed)
          (string/has-prefix? "* " trimmed)
          (string/has-prefix? "+ " trimmed))
      (let [text (string/slice trimmed 2)]
        (array/push lines (line (span "• " (styles :list-marker))
                                (span text style-default))))

      # Code block (starts with ```)
      (string/has-prefix? "```" trimmed)
      (array/push lines (line (span raw-line (styles :code-block))))

      # Regular text
      (array/push lines (line (span raw-line style-default)))))

  lines)

# ── Widget and ANSI output ─────────────────────────────────────

(defn markdown->text [md-text]
  "Convert markdown to a text widget"
  (def lines (markdown->lines md-text))
  {:type :text
   :lines lines
   :render (fn [self area buf]
             (def lines (self :lines))
             (for i 0 (min (length lines) (area :height))
               (def ln (get lines i))
               (var col (area :x))
               (def limit (+ (area :x) (area :width)))
               (each s (ln :spans)
                 (when (>= col limit) (break))
                 (def text (s :text))
                 (def st (s :style))
                 (each byte text
                   (when (>= col limit) (break))
                   (buffer-set-char buf col (+ (area :y) i) (string/from-bytes byte) st)
                   (++ col)))))})

(defn markdown->ansi [md-text]
  "Convert markdown to inline ANSI string"
  (def lines (markdown->lines md-text))
  (def ansi-lines @[])
  (each ln lines
    (array/push ansi-lines (line->str ln)))
  (string/join ansi-lines "\n"))

# ── Simple streaming parser ────────────────────────────────────

(defn create-chat-markdown-parser [output-callback]
  "Create a streaming markdown parser for chat integration.
   Processes complete lines and calls output-callback with span arrays."

  (def buffer @"")

  (def feed-fn (fn [text]
                 (buffer/push buffer text)

                 # Process complete lines (ending with newline)
                 (var start 0)
                 (def buf-str (string buffer))
                 (var pos (string/find "\n" buf-str start))

                 (while pos
                   (def line-text (string/slice buf-str start pos))
                   (def trimmed (string/trim line-text))

                   # Create spans for this line
                   (def spans
                     (cond
                       # Empty line
                       (= trimmed "")
                       @[(span "" style-default)]

                       # Header
                       (string/has-prefix? "#" trimmed)
                       (let [space-pos (string/find " " trimmed)
                             level (if space-pos space-pos (length trimmed))
                             level (min 6 level)
                             text (if space-pos (string/trim (string/slice trimmed level)) trimmed)
                             header-style (get styles (keyword "h" (string level)))]
                         @[(span text header-style)])

                       # List item
                       (or (string/has-prefix? "- " trimmed)
                           (string/has-prefix? "* " trimmed)
                           (string/has-prefix? "+ " trimmed))
                       (let [text (string/slice trimmed 2)]
                         @[(span "• " (styles :list-marker))
                           (span text style-default)])

                       # Code block
                       (string/has-prefix? "```" trimmed)
                       @[(span line-text (styles :code-block))]

                       # Regular text
                       @[(span line-text style-default)]))

                   (output-callback spans)
                   (set start (+ pos 1))
                   (set pos (string/find "\n" buf-str start)))

                 # Remove processed content from buffer
                 (when (> start 0)
                   (def remaining (string/slice buf-str start))
                   (buffer/clear buffer)
                   (buffer/push buffer remaining))))

  (def finish-fn (fn []
                   (def buf-str (string buffer))
                   (when (> (length buf-str) 0)
                     (output-callback @[(span buf-str style-default)]))
                   (buffer/clear buffer)))

  @{:feed feed-fn :finish finish-fn})

# Export convenience
(def md-styles styles)
