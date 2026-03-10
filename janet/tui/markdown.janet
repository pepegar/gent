# tui/markdown.janet — Streaming markdown to ANSI renderer.

(use ./text)
(use ./style)
(use ./buffer)
(use ./charwidth)

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
  "Parse inline markdown (bold, italic, code, links) and return an array of spans.
   Handles **bold**, *italic*, ***bold+italic***, `code`, and [text](url)."
  (if (and (not (string/find "*" text))
           (not (string/find "`" text))
           (not (string/find "[" text)))
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
        (cond
          # Markdown link: [text](url)
          (= ch (chr "["))
          (do
            # Look for closing ] then (url)
            (def close-bracket (string/find "]" text (+ pos 1)))
            (if (and close-bracket
                     (< (+ close-bracket 1) len)
                     (= (get text (+ close-bracket 1)) (chr "(")))
              (do
                (def close-paren (string/find ")" text (+ close-bracket 2)))
                (if close-paren
                  (do
                    # Flush current buffer
                    (when (> (length buf) 0)
                      (array/push result (span (string buf) (compute-inline-style bold italic base-style)))
                      (buffer/clear buf))
                    (def link-text (string/slice text (+ pos 1) close-bracket))
                    (def link-url (string/slice text (+ close-bracket 2) close-paren))
                    (def link-style (style-merge (styles :link) (style :link link-url)))
                    (array/push result (span link-text link-style))
                    (set pos (+ close-paren 1)))
                  (do
                    # No closing paren — treat as literal
                    (buffer/push buf ch)
                    (++ pos))))
              (do
                # No matching ]( — treat as literal
                (buffer/push buf ch)
                (++ pos))))

          # Backtick code span
          (= ch (chr "`"))
          (do
            # Flush current buffer
            (when (> (length buf) 0)
              (array/push result (span (string buf) (compute-inline-style bold italic base-style)))
              (buffer/clear buf))
            # Count opening backticks
            (var tick-count 0)
            (while (and (< (+ pos tick-count) len)
                        (= (get text (+ pos tick-count)) (chr "`")))
              (++ tick-count))
            (+= pos tick-count)
            # Find matching closing backticks
            (def code-buf @"")
            (var found-close false)
            (while (and (< pos len) (not found-close))
              (if (= (get text pos) (chr "`"))
                (do
                  (var close-count 0)
                  (while (and (< (+ pos close-count) len)
                              (= (get text (+ pos close-count)) (chr "`")))
                    (++ close-count))
                  (if (= close-count tick-count)
                    (do
                      (set found-close true)
                      (+= pos close-count))
                    (do
                      # Not matching — include these backticks as literal text
                      (for _ 0 close-count
                        (buffer/push code-buf (chr "`")))
                      (+= pos close-count))))
                (do
                  (buffer/push code-buf (get text pos))
                  (++ pos))))
            (if found-close
              (array/push result (span (string code-buf) (styles :code)))
              (do
                # No closing backticks — render opening backticks + content literally
                (array/push result (span (string (string/repeat "`" tick-count) (string code-buf))
                                         (compute-inline-style bold italic base-style))))))

          # Star markers for bold/italic
          (= ch (chr "*"))
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

          # Regular character
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

# ── Table parsing helpers ─────────────────────────────────────

(defn- table-row? [trimmed]
  "Check if a trimmed line looks like a markdown table row (has | delimiters)."
  (and (string/has-prefix? "|" trimmed)
       (string/has-suffix? "|" trimmed)
       (> (length trimmed) 1)))

(defn- table-separator? [trimmed]
  "Check if a trimmed line is a table separator row (e.g. |---|---|)."
  (and (table-row? trimmed)
       (do
         (var all-sep true)
         (each byte trimmed
           (unless (or (= byte (chr "|"))
                       (= byte (chr "-"))
                       (= byte (chr ":"))
                       (= byte (chr " ")))
             (set all-sep false)))
         all-sep)
       # Must have at least one --- segment
       (not (nil? (string/find "-" trimmed)))))

(defn- parse-table-cells [row-text]
  "Parse a table row into an array of trimmed cell strings."
  (def trimmed (string/trim row-text))
  # Strip leading and trailing |
  (def inner (string/slice trimmed 1 (- (length trimmed) 1)))
  (def raw-cells (string/split "|" inner))
  (map string/trim raw-cells))

(defn- strip-inline-markers [text]
  "Return the display width of text after stripping inline markdown markers (*, `, **, [text](url))."
  (var display-width 0)
  (var pos 0)
  (def len (length text))
  (while (< pos len)
    (def ch (get text pos))
    (cond
      # Skip * markers (bold/italic)
      (= ch (chr "*"))
      (do
        (while (and (< pos len) (= (get text pos) (chr "*")))
          (++ pos)))
      # Skip ` markers (inline code)
      (= ch (chr "`"))
      (do
        (while (and (< pos len) (= (get text pos) (chr "`")))
          (++ pos)))
      # Markdown link [text](url) — count only the text part
      (= ch (chr "["))
      (do
        (def close-bracket (string/find "]" text (+ pos 1)))
        (if (and close-bracket
                 (< (+ close-bracket 1) len)
                 (= (get text (+ close-bracket 1)) (chr "(")))
          (do
            (def close-paren (string/find ")" text (+ close-bracket 2)))
            (if close-paren
              (do
                # Count display width of link text only
                (def link-text (string/slice text (+ pos 1) close-bracket))
                (+= display-width (string-width link-text))
                (set pos (+ close-paren 1)))
              (do
                # No closing paren — count [ as literal
                (++ display-width)
                (++ pos))))
          (do
            # No ]( — count [ as literal
            (++ display-width)
            (++ pos))))
      # Count display width of regular characters (UTF-8 aware)
      (do
        (def byte (get text pos))
        (def char-len
          (cond (< byte 0x80) 1 (< byte 0xE0) 2 (< byte 0xF0) 3 4))
        (def end (min (+ pos char-len) len))
        (def c (string/slice text pos end))
        (+= display-width (char-width c))
        (set pos end))))
  display-width)

(defn- compute-col-widths [rows]
  "Compute the max width per column across all rows.
   Uses display width (stripping inline markdown markers) for accurate alignment."
  (def ncols (length (first rows)))
  (def widths (array/new ncols))
  (for c 0 ncols (array/push widths 0))
  (each row rows
    (for c 0 (min ncols (length row))
      (def w (strip-inline-markers (get row c)))
      (when (> w (get widths c))
        (put widths c w))))
  widths)

(defn- pad-right [text width]
  "Pad text with spaces to the given display width (UTF-8 aware)."
  (def need (- width (string-width text)))
  (if (<= need 0)
    text
    (string text (string/repeat " " need))))

(defn- render-table-line [cells widths cell-style]
  "Render a table data row as a line with styled spans."
  (def spans @[])
  (def border-style (styles :list-marker))
  (def ncols (min (length cells) (length widths)))
  (array/push spans (span "│" border-style))
  (for c 0 ncols
    (def cell-text (get cells c ""))
    (def display-width (strip-inline-markers cell-text))
    (def col-width (get widths c 0))
    (def pad-amount (- col-width display-width))
    (array/push spans (span " " style-default))
    (array/concat spans (parse-inline-spans cell-text cell-style))
    (when (> pad-amount 0)
      (array/push spans (span (string/repeat " " pad-amount) style-default)))
    (array/push spans (span " " style-default))
    (array/push spans (span "│" border-style)))
  (line ;spans))

(defn- render-table-border [widths ch]
  "Render a horizontal border line (top, middle, or bottom).
   ch is the crossing character style: :top :mid :bot"
  (def border-style (styles :list-marker))
  (def [left cross right]
    (case ch
      :top ["┌" "┬" "┐"]
      :mid ["├" "┼" "┤"]
      :bot ["└" "┴" "┘"]))
  (def spans @[])
  (array/push spans (span left border-style))
  (for c 0 (length widths)
    (when (> c 0)
      (array/push spans (span cross border-style)))
    # +2 for the spaces on each side of cell content
    (array/push spans (span (string/repeat "─" (+ (get widths c) 2)) border-style)))
  (array/push spans (span right border-style))
  (line ;spans))

(defn- render-table [header-cells data-rows widths]
  "Render a complete table as an array of lines."
  (def result @[])
  (array/push result (render-table-border widths :top))
  (array/push result (render-table-line header-cells widths (styles :bold)))
  (array/push result (render-table-border widths :mid))
  (each row data-rows
    (array/push result (render-table-line row widths style-default)))
  (array/push result (render-table-border widths :bot))
  result)

# ── Complete markdown parsing (non-streaming) ──────────────────

(defn- flush-table-rows [lines table-rows]
  "Process accumulated table rows and append rendered lines."
  (when (>= (length table-rows) 2)
    (def first-row (get table-rows 0))
    (def second-row (get table-rows 1))
    (if (table-separator? (string/trim second-row))
      (do
        # Standard table: header + separator + data rows
        (def header-cells (parse-table-cells first-row))
        (def data-rows @[])
        (for i 2 (length table-rows)
          (def trimmed (string/trim (get table-rows i)))
          (when (and (table-row? trimmed) (not (table-separator? trimmed)))
            (array/push data-rows (parse-table-cells (get table-rows i)))))
        (def all-rows @[header-cells ;data-rows])
        (def widths (compute-col-widths all-rows))
        (each ln (render-table header-cells data-rows widths)
          (array/push lines ln)))
      (do
        # No separator — just render rows as plain data table (no header distinction)
        (def all-cells @[])
        (each row table-rows
          (def trimmed (string/trim row))
          (when (and (table-row? trimmed) (not (table-separator? trimmed)))
            (array/push all-cells (parse-table-cells row))))
        (when (> (length all-cells) 0)
          (def widths (compute-col-widths all-cells))
          (array/push lines (render-table-border widths :top))
          (each row all-cells
            (array/push lines (render-table-line row widths style-default)))
          (array/push lines (render-table-border widths :bot))))))
  # Edge case: single row (shouldn't happen normally, but be defensive)
  (when (= (length table-rows) 1)
    (def cells (parse-table-cells (get table-rows 0)))
    (def widths (compute-col-widths @[cells]))
    (array/push lines (render-table-border widths :top))
    (array/push lines (render-table-line cells widths style-default))
    (array/push lines (render-table-border widths :bot))))

(defn markdown->lines [md-text]
  "Convert markdown text to a sequence of styled lines"
  (def lines @[])
  (def raw-lines (string/split "\n" md-text))
  (var in-code-block false)
  (var table-rows @[])

  (each raw-line raw-lines
    (def trimmed (string/trim raw-line))

    (if (string/has-prefix? "```" trimmed)
      (do
        # Flush any pending table
        (when (> (length table-rows) 0)
          (flush-table-rows lines table-rows)
          (set table-rows @[]))
        (set in-code-block (not in-code-block))
        (array/push lines (line (span raw-line (styles :code-block)))))
      (if in-code-block
        (array/push lines (line (span raw-line (styles :code-block))))
        (if (table-row? trimmed)
          # Accumulate table rows
          (array/push table-rows raw-line)
          (do
            # Non-table line — flush any pending table first
            (when (> (length table-rows) 0)
              (flush-table-rows lines table-rows)
              (set table-rows @[]))
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

              # Regular text — apply inline formatting
              (array/push lines (line ;(parse-inline-spans raw-line style-default)))))))))

  # Flush any trailing table
  (when (> (length table-rows) 0)
    (flush-table-rows lines table-rows))

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
   Processes complete lines and calls output-callback with span arrays.
   Tracks fenced code block state so inline formatting is suppressed inside."

  (def buffer @"")
  (var in-code-block false)
  (var table-rows @[])

  (def flush-table (fn []
                    (when (> (length table-rows) 0)
                      (def table-lines @[])
                      (flush-table-rows table-lines table-rows)
                      (each ln table-lines
                        (output-callback (ln :spans)))
                      (set table-rows @[]))))

  (def parse-line (fn [line-text]
                    (def trimmed (string/trim line-text))
                    (if (string/has-prefix? "```" trimmed)
                      (do
                        (flush-table)
                        (set in-code-block (not in-code-block))
                        @[(span line-text (styles :code-block))])
                      (if in-code-block
                        @[(span line-text (styles :code-block))]
                        (if (table-row? trimmed)
                          (do
                            (array/push table-rows line-text)
                            nil)
                          (do
                            (flush-table)
                            (parse-line-spans line-text)))))))

  (def feed-fn (fn [text]
                 (buffer/push buffer text)

                 # Process complete lines (ending with newline)
                 (var start 0)
                 (def buf-str (string buffer))
                 (var pos (string/find "\n" buf-str start))

                 (while pos
                   (def line-text (string/slice buf-str start pos))
                   (def result (parse-line line-text))
                   (when result
                     (output-callback result))
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
                     (def result (parse-line buf-str))
                     (when result
                       (output-callback result)))
                   (flush-table)
                   (buffer/clear buffer)))

  @{:feed feed-fn :finish finish-fn})

# Export convenience — md-styles is an alias for the (now mutable) styles table.
(def md-styles styles)
