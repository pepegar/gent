# test/test-markdown.janet — Test markdown to ANSI renderer

(import test/helper :as t)

# Set up module path for relative imports
(array/push module/paths ["./:all:.janet" :source])
(import tui/markdown :as md)

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

(defn test-table-ansi-output []
  (def sample "| A | B |\n|---|---|\n| 1 | 2 |")
  (def ansi (md/markdown->ansi sample))
  (t/assert-truthy (string/find "A" ansi))
  (t/assert-truthy (string/find "B" ansi))
  (t/assert-truthy (string/find "1" ansi))
  (t/assert-truthy (string/find "2" ansi)))

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
(t/test "table ansi output" test-table-ansi-output)
