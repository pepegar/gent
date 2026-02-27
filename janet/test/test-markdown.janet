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

# Run tests
(t/test "basic parsing" test-basic-parsing)
(t/test "list items" test-list-items) 
(t/test "ansi output" test-ansi-output)
(t/test "streaming parser" test-streaming-parser)
