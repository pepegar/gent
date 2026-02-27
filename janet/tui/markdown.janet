# tui/markdown.janet — Streaming markdown to ANSI renderer.

(use ./text)
(use ./style)
(use ./buffer)

# Style definitions — mutable so themes can update them at runtime.
# Dark-mode defaults; call (set-md-styles overrides) to adapt for light mode.
(def styles
  @{:h1 (style :fg :bright-white :bold true)
    :h2 (style :fg :bright-white :bold true)
    :h3 (style :fg :white :bold true)
    :h4 (style :fg :white :bold true)
    :h5 (style :fg :white)
    :h6 (style :fg :white)
    :bold (style :bold true)
    :italic (style :italic true)
    :bold-italic (style :bold true :italic true)
    :code (style :fg :cyan :bg :bright-black)
    :link (style :fg :blue :underline true)
    :list-marker (style :fg :yellow)
    :code-block (style :fg :cyan :bg :bright-black)})

(defn set-md-styles
  "Merge overrides into the active markdown styles table.
   Called by the theme system when switching dark/light."
  [overrides]
  (eachp [k v] overrides
    (put styles k v)))

# ── Inline formatting parser ──────────────────────────────────

(defn- compute-inline-style [bold italic base-style]
  (cond
    (and bold italic) (styles :bold-italic)
    bold (styles :bold)
    italic (styles :italic)
    base-style))

(defn- parse-inline-spans [text base-style]
  "Parse inline markdown (bold, italic) and return an array of spans.
   Handles **bold**, *italic*, and ***bold+italic***."
  (if (not (string/find "*" text))
    @[(span text base-style)]
    (do
      (def result @[])
      (var pos 0)
      (var bold false)
      (var italic false)
      (def buf @"")
      (def len (length text))

      (while (< pos len)
        (def ch (get text pos))
        (if (= ch (chr "*"))
          (do
            # Count consecutive *s
            (var star-count 0)
            (while (and (< (+ pos star-count) len)
                        (= (get text (+ pos star-count)) (chr "*")))
              (++ star-count))
            # Flush current buffer
            (when (> (length buf) 0)
              (array/push result (span (string buf) (compute-inline-style bold italic base-style)))
              (buffer/clear buf))
            # Toggle formatting based on star count
            (cond
              (>= star-count 3) (do (set bold (not bold)) (set italic (not italic)))
              (= star-count 2) (set bold (not bold))
              (set italic (not italic)))
            (set pos (+ pos star-count)))
          (do
            (buffer/push buf ch)
            (++ pos))))

      # Flush remaining
      (when (> (length buf) 0)
        (array/push result (span (string buf) (compute-inline-style bold italic base-style))))

      (if (empty? result)
        @[(span text base-style)]
        result))))

(defn- numbered-list-text [trimmed]
  "If trimmed is a numbered list item (e.g. '1. text'), return the text. Otherwise nil."
  (def dot-space (string/find ". " trimmed))
  (when (and dot-space (> dot-space 0))
    (def prefix (string/slice trimmed 0 dot-space))
    (var all-digits true)
    (each byte prefix
      (when (or (< byte (chr "0")) (> byte (chr "9")))
        (set all-digits false)))
    (when all-digits
      (string/slice trimmed (+ dot-space 2)))))

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
        (array/push lines (line ;(parse-inline-spans text header-style))))

      # Unordered list item (starts with -, *, +)
      (or (string/has-prefix? "- " trimmed)
          (string/has-prefix? "* " trimmed)
          (string/has-prefix? "+ " trimmed))
      (let [text (string/slice trimmed 2)]
        (array/push lines (line (span "• " (styles :list-marker))
                                ;(parse-inline-spans text style-default))))

      # Numbered list item
      (numbered-list-text trimmed)
      (let [text (numbered-list-text trimmed)
            dot-pos (string/find ". " trimmed)
            marker (string (string/slice trimmed 0 dot-pos) ". ")]
        (array/push lines (line (span marker (styles :list-marker))
                                ;(parse-inline-spans text style-default))))

      # Code block (starts with ```)
      (string/has-prefix? "```" trimmed)
      (array/push lines (line (span raw-line (styles :code-block))))

      # Regular text — apply inline formatting
      (array/push lines (line ;(parse-inline-spans raw-line style-default)))))

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

(defn- parse-line-spans [line-text]
  "Parse a single line of markdown into an array of spans."
  (def trimmed (string/trim line-text))
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
      (parse-inline-spans text header-style))

    # Unordered list item
    (or (string/has-prefix? "- " trimmed)
        (string/has-prefix? "* " trimmed)
        (string/has-prefix? "+ " trimmed))
    (let [text (string/slice trimmed 2)]
      (array/concat @[(span "• " (styles :list-marker))]
                    (parse-inline-spans text style-default)))

    # Numbered list item
    (numbered-list-text trimmed)
    (let [text (numbered-list-text trimmed)
          dot-pos (string/find ". " trimmed)
          marker (string (string/slice trimmed 0 dot-pos) ". ")]
      (array/concat @[(span marker (styles :list-marker))]
                    (parse-inline-spans text style-default)))

    # Code block
    (string/has-prefix? "```" trimmed)
    @[(span line-text (styles :code-block))]

    # Regular text — apply inline formatting
    (parse-inline-spans line-text style-default)))

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
                   (output-callback (parse-line-spans line-text))
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
                     (output-callback (parse-line-spans buf-str)))
                   (buffer/clear buffer)))

  @{:feed feed-fn :finish finish-fn})

# Export convenience — md-styles is an alias for the (now mutable) styles table.
(def md-styles styles)
