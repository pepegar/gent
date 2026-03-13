# test/test-markdown.janet — Test markdown to ANSI renderer

(import test/helper :as t)

# Set up module path for relative imports
(array/push module/paths ["./:all:.janet" :source])
(import tui/markdown :as md)
(import tui/text :as text)

(defn test-basic-parsing []
  (def sample "# Hello World\nThis is regular text.")
  (def lines (md/markdown->lines sample))
  
  # Should have 2 lines
  (t/assert= 2 (length lines))
  
  # First line should be a header
  (def header-line (first lines))
  (t/assert= 1 (length (header-line :spans)))
  (def header-span (first (header-line :spans)))
  (t/assert= "Hello World" (header-span :text)))

(defn test-list-items []
  (def sample "- Item 1\n- Item 2")
  (def lines (md/markdown->lines sample))
  
  # Should have 2 lines
  (t/assert= 2 (length lines))
  
  # Each line should start with bullet
  (def first-line (first lines))
  (def first-span (first (first-line :spans)))
  (t/assert= "• " (first-span :text)))

(defn test-ansi-output []
  (def sample "# Header\nRegular text")
  (def ansi (md/markdown->ansi sample))
  
  # Should contain header and text
  (t/assert-truthy (string/find "Header" ansi))
  (t/assert-truthy (string/find "Regular text" ansi)))

(defn test-streaming-parser []
  (def output @[])
  (def parser (md/create-chat-markdown-parser 
               (fn [line-spans] (array/push output line-spans))))
  
  # Feed markdown text in chunks
  ((parser :feed) "#")
  ((parser :feed) " Hello")
  ((parser :feed) "\n")
  ((parser :feed) "Regular")
  ((parser :feed) " text")
  ((parser :feed) "\n")
  ((parser :finish))
  
  # Should have processed 2 lines
  (t/assert= 2 (length output))
  
  # First line should be header
  (def first-line (first output))
  (t/assert= 1 (length first-line))
  (t/assert= "Hello" ((first first-line) :text)))

(defn test-inline-bold []
  (def sample "This is **bold** text.")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  # Should have 3 spans: "This is ", "bold", " text."
  (t/assert= 3 (length spans))
  (t/assert= "This is " ((get spans 0) :text))
  (t/assert= "bold" ((get spans 1) :text))
  (t/assert-truthy (get-in spans [1 :style :bold]))
  (t/assert= " text." ((get spans 2) :text)))

(defn test-inline-italic []
  (def sample "This is *italic* text.")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  (t/assert= 3 (length spans))
  (t/assert= "This is " ((get spans 0) :text))
  (t/assert= "italic" ((get spans 1) :text))
  (t/assert-truthy (get-in spans [1 :style :italic]))
  (t/assert= " text." ((get spans 2) :text)))

(defn test-inline-bold-italic []
  (def sample "This is ***both*** text.")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  (t/assert= 3 (length spans))
  (t/assert= "both" ((get spans 1) :text))
  (t/assert-truthy (get-in spans [1 :style :bold]))
  (t/assert-truthy (get-in spans [1 :style :italic])))

(defn test-no-stars-passthrough []
  (def sample "Plain text without any formatting.")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  (t/assert= 1 (length spans))
  (t/assert= sample ((get spans 0) :text)))

(defn test-numbered-list []
  (def sample "1. First item\n2. Second item\n10. Tenth item")
  (def lines (md/markdown->lines sample))
  (t/assert= 3 (length lines))
  # Each line should start with the number marker
  (def first-spans ((get lines 0) :spans))
  (t/assert= "1. " ((get first-spans 0) :text))
  (t/assert= "First item" ((get first-spans 1) :text))
  (def second-spans ((get lines 1) :spans))
  (t/assert= "2. " ((get second-spans 0) :text))
  (def tenth-spans ((get lines 2) :spans))
  (t/assert= "10. " ((get tenth-spans 0) :text)))

(defn test-numbered-list-not-false-positive []
  (def sample "This sentence has a 1. in it.")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  # Should NOT be parsed as a numbered list — it starts with "This"
  (def spans ((first lines) :spans))
  (t/assert= 1 (length spans)))

(defn test-inline-bold-in-list []
  (def sample "- A **bold** item")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  # bullet "• ", "A ", "bold", " item"
  (t/assert= "• " ((get spans 0) :text))
  (t/assert= "A " ((get spans 1) :text))
  (t/assert= "bold" ((get spans 2) :text))
  (t/assert-truthy (get-in spans [2 :style :bold])))

(defn test-inline-in-header []
  (def sample "## A *fancy* title")
  (def lines (md/markdown->lines sample))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  # "A " in header style, "fancy" in bold+italic (header is already bold), " title" in header style
  (t/assert= 3 (length spans))
  (t/assert= "fancy" ((get spans 1) :text))
  (t/assert-truthy (get-in spans [1 :style :italic])))

(defn test-streaming-inline-bold []
  (def output @[])
  (def parser (md/create-chat-markdown-parser
                (fn [spans] (array/push output spans))))
  ((parser :feed) "This is **bold** text.\n")
  ((parser :finish))
  (t/assert= 1 (length output))
  (def spans (get output 0))
  (t/assert= 3 (length spans))
  (t/assert= "bold" ((get spans 1) :text))
  (t/assert-truthy (get-in spans [1 :style :bold])))

(defn test-streaming-numbered-list []
  (def output @[])
  (def parser (md/create-chat-markdown-parser
                (fn [spans] (array/push output spans))))
  ((parser :feed) "1. First\n2. Second\n")
  ((parser :finish))
  (t/assert= 2 (length output))
  (def first-spans (get output 0))
  (t/assert= "1. " ((get first-spans 0) :text))
  (t/assert= "First" ((get first-spans 1) :text)))

(defn test-code-block-preserves-asterisks []
  (def sample "```janet\n(def idx (+ (* row w) col))\n```")
  (def lines (md/markdown->lines sample))
  (t/assert= 3 (length lines))
  (def code-line (get lines 1))
  (def spans (code-line :spans))
  (t/assert= 1 (length spans))
  (t/assert= "(def idx (+ (* row w) col))" ((get spans 0) :text)))

(defn test-streaming-code-block-preserves-asterisks []
  (def output @[])
  (def parser (md/create-chat-markdown-parser
                (fn [spans] (array/push output spans))))
  ((parser :feed) "```janet\n(def idx (+ (* row w) col))\n```\n")
  ((parser :finish))
  (t/assert= 3 (length output))
  (def code-spans (get output 1))
  (t/assert= 1 (length code-spans))
  (t/assert= "(def idx (+ (* row w) col))" ((get code-spans 0) :text)))

(defn test-table-basic []
  (def sample "| Name | Age |\n|------|-----|\n| Alice | 30 |\n| Bob | 25 |")
  (def lines (md/markdown->lines sample))
  # Should produce: top border, header, mid border, 2 data rows, bottom border = 6 lines
  (t/assert= 6 (length lines))
  # Check top border has box-drawing characters
  (def top-text (string ;(map |($ :text) ((get lines 0) :spans))))
  (t/assert-truthy (string/find "┌" top-text))
  (t/assert-truthy (string/find "┬" top-text))
  (t/assert-truthy (string/find "┐" top-text))
  # Check header row contains cell text
  (def header-text (string ;(map |($ :text) ((get lines 1) :spans))))
  (t/assert-truthy (string/find "Name" header-text))
  (t/assert-truthy (string/find "Age" header-text))
  # Check header is bold
  (var found-bold false)
  (each s ((get lines 1) :spans)
    (when (and (string/find "Name" (s :text))
               (get (s :style) :bold))
      (set found-bold true)))
  (t/assert-truthy found-bold)
  # Check middle border
  (def mid-text (string ;(map |($ :text) ((get lines 2) :spans))))
  (t/assert-truthy (string/find "├" mid-text))
  (t/assert-truthy (string/find "┼" mid-text))
  # Check data rows
  (def row1-text (string ;(map |($ :text) ((get lines 3) :spans))))
  (t/assert-truthy (string/find "Alice" row1-text))
  (def row2-text (string ;(map |($ :text) ((get lines 4) :spans))))
  (t/assert-truthy (string/find "Bob" row2-text))
  # Check bottom border
  (def bot-text (string ;(map |($ :text) ((get lines 5) :spans))))
  (t/assert-truthy (string/find "└" bot-text))
  (t/assert-truthy (string/find "┴" bot-text))
  (t/assert-truthy (string/find "┘" bot-text)))

(defn test-table-column-alignment []
  (def sample "| Short | A much longer column |\n|-------|----------------------|\n| x | y |")
  (def lines (md/markdown->lines sample))
  (t/assert= 5 (length lines))
  # The columns should be padded to align
  (def header-text (string ;(map |($ :text) ((get lines 1) :spans))))
  (def data-text (string ;(map |($ :text) ((get lines 3) :spans))))
  # Both rows should have the same total width (same border positions)
  (t/assert= (length header-text) (length data-text)))

(defn test-table-inline-formatting []
  (def sample "| Name | Status |\n|------|--------|\n| Alice | **active** |")
  (def lines (md/markdown->lines sample))
  (t/assert= 5 (length lines))
  # Data row should have bold "active"
  (var found-bold false)
  (each s ((get lines 3) :spans)
    (when (and (string/find "active" (s :text))
               (get (s :style) :bold))
      (set found-bold true)))
  (t/assert-truthy found-bold))

(defn test-table-mixed-with-text []
  (def sample "Some text before\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nSome text after")
  (def lines (md/markdown->lines sample))
  # Should have: text, blank, table (5 lines), blank, text = 9
  (t/assert= 9 (length lines))
  (def first-text (string ;(map |($ :text) ((get lines 0) :spans))))
  (t/assert-truthy (string/find "Some text before" first-text))
  (def last-text (string ;(map |($ :text) ((get lines 8) :spans))))
  (t/assert-truthy (string/find "Some text after" last-text)))

(defn test-table-at-end-of-text []
  (def sample "Here is a table:\n| X | Y |\n|---|---|\n| 1 | 2 |")
  (def lines (md/markdown->lines sample))
  # text + table (5 lines) = 6
  (t/assert= 6 (length lines))
  (def first-text (string ;(map |($ :text) ((get lines 0) :spans))))
  (t/assert-truthy (string/find "Here is a table:" first-text)))

(defn test-table-streaming []
  (def output @[])
  (def parser (md/create-chat-markdown-parser
                (fn [spans] (array/push output spans))))
  ((parser :feed) "| Name | Age |\n")
  ((parser :feed) "|------|-----|\n")
  ((parser :feed) "| Alice | 30 |\n")
  ((parser :feed) "| Bob | 25 |\n")
  ((parser :feed) "\n")
  ((parser :finish))
  # Table should be flushed when the empty line arrives
  # 6 table lines + 1 empty line = 7
  (t/assert= 7 (length output))
  # First line should be top border
  (def top-text (string ;(map |($ :text) (get output 0))))
  (t/assert-truthy (string/find "┌" top-text))
  # Second line should have header text
  (def header-text (string ;(map |($ :text) (get output 1))))
  (t/assert-truthy (string/find "Name" header-text)))

(defn test-table-streaming-at-finish []
  (def output @[])
  (def parser (md/create-chat-markdown-parser
                (fn [spans] (array/push output spans))))
  ((parser :feed) "| A | B |\n|---|---|\n| 1 | 2 |\n")
  ((parser :finish))
  # Table flushed on finish: 5 lines
  (t/assert= 5 (length output))
  (def top-text (string ;(map |($ :text) (get output 0))))
  (t/assert-truthy (string/find "┌" top-text)))

(defn test-table-inline-bold-column-alignment []
  (def sample "| Tool | Purpose |\n|------|------|\n| **bash** | Execute shell commands |\n| **read_file** | Read file contents |")
  (def lines (md/markdown->lines sample))
  # top border, header, mid border, 2 data rows, bottom border = 6
  (t/assert= 6 (length lines))
  # All rendered lines must have the same visual (display) width so borders align.
  # Use line-width which counts display columns, not byte length.
  (def widths (map |(text/line-width $) lines))
  (def first-width (get widths 0))
  (each w widths
    (t/assert= first-width w)))

(defn test-table-ansi-output []
  (def sample "| A | B |\n|---|---|\n| 1 | 2 |")
  (def ansi (md/markdown->ansi sample))
  (t/assert-truthy (string/find "A" ansi))
  (t/assert-truthy (string/find "B" ansi))
  (t/assert-truthy (string/find "1" ansi))
  (t/assert-truthy (string/find "2" ansi)))

(defn test-table-backtick-code-alignment []
  (def sample "| Name | Symbol |\n|------|--------|\n| gutter | `▐` |\n| check | `✓` |")
  (def lines (md/markdown->lines sample))
  (t/assert= 6 (length lines))
  # All rendered lines must have the same visual width so borders align
  (def widths (map |(text/line-width $) lines))
  (def first-width (get widths 0))
  (each w widths
    (t/assert= first-width w)))

(defn test-table-unicode-width-alignment []
  (def sample "| Test | What it verifies |\n|------|------------------|\n| `output-user` | Each `\\n` creates entries |\n| `snapshot: multi-line` | All lines render on separate rows |")
  (def lines (md/markdown->lines sample))
  (t/assert= 6 (length lines))
  (def widths (map |(text/line-width $) lines))
  (def first-width (get widths 0))
  (each w widths
    (t/assert= first-width w)))

(defn test-inline-code-span []
  (def lines (md/markdown->lines "Use `foo` and `bar` here"))
  (t/assert= 1 (length lines))
  (def spans ((first lines) :spans))
  # Should have: "Use " code("foo") " and " code("bar") " here"
  (t/assert-truthy (>= (length spans) 5))
  # Find the code spans
  (var found-foo false)
  (var found-bar false)
  (each s spans
    (when (= (s :text) "foo") (set found-foo true))
    (when (= (s :text) "bar") (set found-bar true)))
  (t/assert-truthy found-foo)
  (t/assert-truthy found-bar))

# Run tests
(t/test "basic parsing" test-basic-parsing)
(t/test "list items" test-list-items)
(t/test "ansi output" test-ansi-output)
(t/test "streaming parser" test-streaming-parser)
(t/test "inline bold" test-inline-bold)
(t/test "inline italic" test-inline-italic)
(t/test "inline bold+italic" test-inline-bold-italic)
(t/test "no stars passthrough" test-no-stars-passthrough)
(t/test "numbered list" test-numbered-list)
(t/test "numbered list not false positive" test-numbered-list-not-false-positive)
(t/test "inline bold in list" test-inline-bold-in-list)
(t/test "inline in header" test-inline-in-header)
(t/test "streaming inline bold" test-streaming-inline-bold)
(t/test "streaming numbered list" test-streaming-numbered-list)
(t/test "code block preserves asterisks" test-code-block-preserves-asterisks)
(t/test "streaming code block preserves asterisks" test-streaming-code-block-preserves-asterisks)
(t/test "table basic" test-table-basic)
(t/test "table column alignment" test-table-column-alignment)
(t/test "table inline formatting" test-table-inline-formatting)
(t/test "table mixed with text" test-table-mixed-with-text)
(t/test "table at end of text" test-table-at-end-of-text)
(t/test "table streaming" test-table-streaming)
(t/test "table streaming at finish" test-table-streaming-at-finish)
(t/test "table inline bold column alignment" test-table-inline-bold-column-alignment)
(t/test "table ansi output" test-table-ansi-output)
(t/test "table backtick code column alignment" test-table-backtick-code-alignment)
(t/test "table unicode width alignment" test-table-unicode-width-alignment)
(t/test "inline code span" test-inline-code-span)

# ── Link tests ────────────────────────────────────────────────

(defn test-inline-link []
  (def lines (md/markdown->lines "Check [example](https://example.com) here"))
  (t/assert= (length lines) 1)
  (def spans ((first lines) :spans))
  # Should have: "Check " link("example") " here"
  (t/assert-truthy (>= (length spans) 3))
  (var found-link false)
  (each s spans
    (when (and (= (s :text) "example")
               (get (s :style) :link))
      (set found-link true)
      (t/assert= (get (s :style) :link) "https://example.com")
      (t/assert-truthy (get (s :style) :underline))))
  (t/assert-truthy found-link))

(defn test-inline-link-no-url []
  # [text] without (url) should not be a link
  (def lines (md/markdown->lines "See [text] here"))
  (t/assert= (length lines) 1)
  (def spans ((first lines) :spans))
  (each s spans
    (t/assert-falsy (get (s :style) :link))))

(defn test-inline-link-with-bold []
  (def lines (md/markdown->lines "Try **[bold link](https://example.com)**"))
  (t/assert= (length lines) 1)
  (def spans ((first lines) :spans))
  (var found-link false)
  (each s spans
    (when (get (s :style) :link)
      (set found-link true)
      (t/assert= (s :text) "bold link")))
  (t/assert-truthy found-link))

(t/test "inline link" test-inline-link)
(t/test "inline link no url" test-inline-link-no-url)
(t/test "inline link with bold" test-inline-link-with-bold)

# ── Table width-constraining tests ─────────────────────────

(defn test-table-constrained-width []
  # A table that would be ~70 chars wide unconstrained, rendered at max-width 40
  (def sample "| Name | Description |\n|------|-------------|\n| Alice | A very long description that should wrap |\n| Bob | Short |")
  (def lines (md/markdown->lines sample 40))
  # All lines should fit within 40 columns
  (each ln lines
    (t/assert-truthy (<= (text/line-width ln) 40))))

(defn test-table-constrained-all-content-visible []
  # Verify that all cell content appears somewhere in the rendered lines
  (def sample "| Tool | Purpose |\n|------|--------|\n| bash | Execute shell commands |\n| read_file | Read file contents |")
  (def lines (md/markdown->lines sample 30))
  (def all-text (string ;(map (fn [ln] (string ;(map |($ :text) (ln :spans)))) lines)))
  (t/assert-truthy (string/find "bash" all-text))
  (t/assert-truthy (string/find "Execute" all-text))
  (t/assert-truthy (string/find "read_file" all-text))
  (t/assert-truthy (string/find "Read" all-text)))

(defn test-table-unconstrained-unchanged []
  # Without max-width, behavior is the same as before
  (def sample "| A | B |\n|---|---|\n| 1 | 2 |")
  (def lines-no-max (md/markdown->lines sample))
  (def lines-big-max (md/markdown->lines sample 200))
  # Should produce same number of lines
  (t/assert= (length lines-no-max) (length lines-big-max))
  # Each line should have the same width
  (for i 0 (length lines-no-max)
    (t/assert= (text/line-width (get lines-no-max i))
               (text/line-width (get lines-big-max i)))))

(defn test-table-cell-wrapping []
  # A table with a very long cell that must wrap
  (def sample "| Key | Value |\n|-----|-------|\n| x | This is a very long value that definitely needs wrapping |")
  (def lines (md/markdown->lines sample 30))
  # Should produce more than 5 lines (the normal 5 for a 1-row table)
  # because the data row needs to wrap
  (t/assert-truthy (> (length lines) 5))
  # All lines should fit within 30 columns
  (each ln lines
    (t/assert-truthy (<= (text/line-width ln) 30))))

(defn test-table-streaming-constrained []
  (def output @[])
  (def parser (md/create-chat-markdown-parser
                (fn [spans] (array/push output spans))
                30))
  ((parser :feed) "| Name | Description |\n")
  ((parser :feed) "|------|-------------|\n")
  ((parser :feed) "| Alice | A long description here |\n")
  ((parser :feed) "\n")
  ((parser :finish))
  # All output lines should fit within 30 columns
  (each spans output
    (var width 0)
    (each s spans (+= width (text/span-width s)))
    (t/assert-truthy (<= width 30))))

(defn test-table-borders-aligned-after-constraining []
  # When constrained, all border and data lines should still have equal width
  (def sample "| Column One | Column Two | Column Three |\n|------------|------------|-------|\n| data 1 | data 2 | data 3 |")
  (def lines (md/markdown->lines sample 35))
  (def widths (map |(text/line-width $) lines))
  (def first-width (get widths 0))
  (each w widths
    (t/assert= first-width w)))

(t/test "table constrained width" test-table-constrained-width)
(t/test "table constrained all content visible" test-table-constrained-all-content-visible)
(t/test "table unconstrained unchanged" test-table-unconstrained-unchanged)
(t/test "table cell wrapping" test-table-cell-wrapping)
(t/test "table streaming constrained" test-table-streaming-constrained)
(t/test "table borders aligned after constraining" test-table-borders-aligned-after-constraining)
