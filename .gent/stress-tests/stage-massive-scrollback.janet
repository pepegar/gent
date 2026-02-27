# Stage script: Generate massive scrollback for scroll stress testing
# Creates 500 lines of varied content - plain text, markdown, code blocks

(import core/stage :as stage)

(def content
  (string/join
    (seq [i :range [0 500]]
      (cond
        (= (% i 10) 0)
        (string "## Section " (div i 10) "\n\n")

        (= (% i 10) 1)
        (string "Here is a **bold** statement with *italic* and `inline code` on line " i ". This is a fairly long line that should cause word wrapping in a typical terminal window of around 100 columns wide.\n\n")

        (= (% i 10) 5)
        (string "```python\ndef function_" i "(x, y):\n    return x + y * " i "\n```\n\n")

        (= (% i 10) 8)
        (string "- Item " i ": Lorem ipsum dolor sit amet\n- Item " (+ i 1) ": Consectetur adipiscing elit\n- Item " (+ i 2) ": Sed do eiusmod tempor\n\n")

        (string "Line " i ": The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.\n")))
    ""))

(stage/respond (stage/text content))
