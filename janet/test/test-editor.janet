# Tests for core/editor — buffer state and cursor position after editing.
# Uses the mocked term/write from fake-http so no real terminal is needed.
(import core/buffers :as buffers)
(import core/editor :as editor)
(import test/helper :as t)

(print "── core/editor ──")

# ── Helpers ──

(defn- content []
  (buffers/string-content (editor/get-input-buf)))

(defn- cursor []
  (buffers/get-point (editor/get-input-buf)))

(defn- key-ev [key &opt ctrl alt shift]
  @{:type :key
    :key key
    :ctrl (or ctrl false)
    :alt (or alt false)
    :shift (or shift false)})

(defn- type-str [s]
  (each byte s
    (editor/handle-event (key-ev (string/from-bytes byte)))))

(defn- press-enter [] (editor/handle-event (key-ev :enter false false true)))
(defn- press-backspace [] (editor/handle-event (key-ev :backspace)))
(defn- press-delete [] (editor/handle-event (key-ev :delete)))
(defn- press-left [] (editor/handle-event (key-ev :left)))
(defn- press-right [] (editor/handle-event (key-ev :right)))
(defn- press-home [] (editor/handle-event (key-ev :home)))
(defn- press-end [] (editor/handle-event (key-ev :end)))
(defn- ctrl [ch] (editor/handle-event (key-ev ch true)))

(defn- clear []
  (ctrl "u"))

# ── Basic typing ──

(t/test "type hello" (fn []
  (clear)
  (type-str "hello")
  (t/assert= (content) "hello")
  (t/assert= (cursor) 5)))

(t/test "type then newline then type" (fn []
  (clear)
  (type-str "hello")
  (press-enter)
  (type-str "world")
  (t/assert= (content) "hello\nworld")
  (t/assert= (cursor) 11)))

(t/test "multiple newlines" (fn []
  (clear)
  (type-str "a")
  (press-enter)
  (type-str "b")
  (press-enter)
  (type-str "c")
  (t/assert= (content) "a\nb\nc")
  (t/assert= (cursor) 5)))

(t/test "newline then keep typing" (fn []
  (clear)
  (type-str "line1")
  (press-enter)
  (type-str "line2 continued")
  (t/assert= (content) "line1\nline2 continued")
  (t/assert= (cursor) 21)))

# ── Insert in middle ──

(t/test "insert char in middle" (fn []
  (clear)
  (type-str "hllo")
  (press-left) (press-left) (press-left)
  (type-str "e")
  (t/assert= (content) "hello")
  (t/assert= (cursor) 2)))

(t/test "insert at beginning" (fn []
  (clear)
  (type-str "ello")
  (press-home)
  (type-str "h")
  (t/assert= (content) "hello")
  (t/assert= (cursor) 1)))

(t/test "insert newline in middle of text" (fn []
  (clear)
  (type-str "abcdef")
  (press-left) (press-left) (press-left)
  (press-enter)
  (t/assert= (content) "abc\ndef")
  (t/assert= (cursor) 4)))

(t/test "insert newline in middle then type" (fn []
  (clear)
  (type-str "abcdef")
  (press-left) (press-left) (press-left)
  (press-enter)
  (type-str "XY")
  (t/assert= (content) "abc\nXYdef")
  (t/assert= (cursor) 6)))

# ── Backspace ──

(t/test "backspace at end" (fn []
  (clear)
  (type-str "hello")
  (press-backspace)
  (t/assert= (content) "hell")
  (t/assert= (cursor) 4)))

(t/test "backspace at beginning does nothing" (fn []
  (clear)
  (type-str "hi")
  (press-home)
  (press-backspace)
  (t/assert= (content) "hi")
  (t/assert= (cursor) 0)))

(t/test "backspace across newline" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  # cursor is at end: "abc\ndef", cursor=7
  # Move left 3 to get to start of "def"
  (press-left) (press-left) (press-left)
  # cursor at 4 (right after \n)
  (press-backspace)
  (t/assert= (content) "abcdef")
  (t/assert= (cursor) 3)))

(t/test "multiple backspaces" (fn []
  (clear)
  (type-str "hello")
  (press-backspace)
  (press-backspace)
  (press-backspace)
  (t/assert= (content) "he")
  (t/assert= (cursor) 2)))

# ── Delete forward ──

(t/test "delete forward" (fn []
  (clear)
  (type-str "hello")
  (press-home)
  (press-delete)
  (t/assert= (content) "ello")
  (t/assert= (cursor) 0)))

(t/test "delete forward at end does nothing" (fn []
  (clear)
  (type-str "hi")
  (press-delete)
  (t/assert= (content) "hi")
  (t/assert= (cursor) 2)))

(t/test "delete newline forward" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  # Move to just before the \n
  (press-home) # goes to start of "def" line (pos 4)
  (press-left) # now at pos 3 (the \n)
  # Hmm, press-left from start of line 2 should go to... let me think
  # cursor at 4 (start of "def"), press-left → cursor at 3 (the \n char)
  (press-delete)
  (t/assert= (content) "abcdef")
  (t/assert= (cursor) 3)))

# ── Movement ──

(t/test "move left and right" (fn []
  (clear)
  (type-str "abc")
  (t/assert= (cursor) 3)
  (press-left)
  (t/assert= (cursor) 2)
  (press-left)
  (t/assert= (cursor) 1)
  (press-right)
  (t/assert= (cursor) 2)))

(t/test "move home and end" (fn []
  (clear)
  (type-str "hello")
  (press-home)
  (t/assert= (cursor) 0)
  (press-end)
  (t/assert= (cursor) 5)))

(t/test "home goes to start of current line" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  # cursor at 7 (end of "def")
  (press-home)
  (t/assert= (cursor) 4)))

(t/test "end goes to end of current line" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  (press-home)
  # cursor at 4 (start of "def")
  (press-end)
  (t/assert= (cursor) 7)))

# ── Kill line (ctrl-k) ──

(t/test "kill-line from middle" (fn []
  (clear)
  (type-str "hello world")
  (press-home)
  (press-right) (press-right) (press-right) (press-right) (press-right)
  (ctrl "k")
  (t/assert= (content) "hello")
  (t/assert= (cursor) 5)))

(t/test "kill-line at end of line joins with next" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  # Move to end of first line
  (press-home)
  (press-left) # to pos 3 (end of "abc" before \n)
  # Actually let me reconsider. "abc\ndef", press-home → 4 (start of def), press-left → 3 (\n)
  # At pos 3, the char is \n. current-line-end from pos 3 also returns 3 (since \n is a line terminator)
  # So kill-line when cursor is at \n: cur=3, end=3 (current-line-end returns 3 since buf[3]=\n)
  # Since cur == end and cur < length, it deletes the \n
  (ctrl "k")
  (t/assert= (content) "abcdef")
  (t/assert= (cursor) 3)))

# ── Kill word back (ctrl-w) ──

(t/test "kill-word-back" (fn []
  (clear)
  (type-str "hello world")
  (ctrl "w")
  (t/assert= (content) "hello ")
  (t/assert= (cursor) 6)))

(t/test "kill-word-back at start does nothing" (fn []
  (clear)
  (type-str "hello")
  (press-home)
  (ctrl "w")
  (t/assert= (content) "hello")
  (t/assert= (cursor) 0)))

# ── Kill word forward (alt-d) ──

(t/test "kill-word-forward" (fn []
  (clear)
  (type-str "hello world")
  (press-home)
  (editor/handle-event (key-ev "d" false true))
  (t/assert= (content) " world")
  (t/assert= (cursor) 0)))

# ── Clear input (ctrl-u) ──

(t/test "clear-input empties buffer" (fn []
  (clear)
  (type-str "hello world")
  (ctrl "u")
  (t/assert= (content) "")
  (t/assert= (cursor) 0)))

(t/test "clear-input on multiline" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  (ctrl "u")
  (t/assert= (content) "")
  (t/assert= (cursor) 0)))

# ── Transpose (ctrl-t) ──

(t/test "transpose at end" (fn []
  (clear)
  (type-str "ab")
  (ctrl "t")
  (t/assert= (content) "ba")
  (t/assert= (cursor) 2)))

(t/test "transpose in middle" (fn []
  (clear)
  (type-str "abc")
  (press-left)
  # cursor at 2, on 'c'. Transpose swaps 'b' and 'c', cursor advances to 3
  (ctrl "t")
  (t/assert= (content) "acb")
  (t/assert= (cursor) 3)))

# ── Multiline editing sequences ──

(t/test "type line1, newline, type line2, backspace all of line2" (fn []
  (clear)
  (type-str "first")
  (press-enter)
  (type-str "second")
  # Now backspace 6 chars ("second") + 1 (\n) = back to "first"
  (press-backspace) (press-backspace) (press-backspace)
  (press-backspace) (press-backspace) (press-backspace)
  (press-backspace)
  (t/assert= (content) "first")
  (t/assert= (cursor) 5)))

(t/test "insert in middle of first line after adding second line" (fn []
  (clear)
  (type-str "hllo")
  (press-enter)
  (type-str "world")
  # "hllo\nworld", cursor=10
  # Go back to first line and fix: move home twice-ish
  # Move to start of "world" line (home → pos 5)
  (press-home)
  # Move left past \n to end of first line → pos 4
  (press-left)
  # Now home to go to start of first line → pos 0
  (press-home)
  # Insert 'e' after 'h'
  (press-right)
  (type-str "e")
  (t/assert= (content) "hello\nworld")
  (t/assert= (cursor) 2)))

(t/test "three lines with editing" (fn []
  (clear)
  (type-str "aaa")
  (press-enter)
  (type-str "bbb")
  (press-enter)
  (type-str "ccc")
  (t/assert= (content) "aaa\nbbb\nccc")
  (t/assert= (cursor) 11)
  # Delete last char
  (press-backspace)
  (t/assert= (content) "aaa\nbbb\ncc")
  (t/assert= (cursor) 10)
  # Go to middle line and insert
  (press-home)
  (press-left)
  (press-home)
  # Now at start of "bbb" (pos 4)
  (t/assert= (cursor) 4)
  (type-str "X")
  (t/assert= (content) "aaa\nXbbb\ncc")
  (t/assert= (cursor) 5)))

# ── Cursor position consistency after newlines ──

(t/test "cursor tracks correctly through newline sequence" (fn []
  (clear)
  (type-str "a")
  (t/assert= (cursor) 1)
  (press-enter)
  (t/assert= (cursor) 2)
  (t/assert= (content) "a\n")
  (type-str "b")
  (t/assert= (cursor) 3)
  (t/assert= (content) "a\nb")
  (type-str "c")
  (t/assert= (cursor) 4)
  (t/assert= (content) "a\nbc")
  (press-enter)
  (t/assert= (cursor) 5)
  (t/assert= (content) "a\nbc\n")
  (type-str "d")
  (t/assert= (cursor) 6)
  (t/assert= (content) "a\nbc\nd")))

(t/test "rapid type after newline" (fn []
  (clear)
  (press-enter)
  (t/assert= (content) "\n")
  (t/assert= (cursor) 1)
  (type-str "hello")
  (t/assert= (content) "\nhello")
  (t/assert= (cursor) 6)))

(t/test "newline at beginning" (fn []
  (clear)
  (type-str "hello")
  (press-home)
  (press-enter)
  (t/assert= (content) "\nhello")
  (t/assert= (cursor) 1)))

(t/test "insert between two lines" (fn []
  (clear)
  (type-str "abc")
  (press-enter)
  (type-str "def")
  # Move to just after \n (start of line 2)
  (press-home)
  # Insert newline here, pushing "def" down
  (press-enter)
  (t/assert= (content) "abc\n\ndef")
  (t/assert= (cursor) 5)))

# ── Word movement (alt-f, alt-b) ──

(t/test "move-word-forward" (fn []
  (clear)
  (type-str "hello world foo")
  (press-home)
  # alt-f: skip "hello" then spaces
  (editor/handle-event (key-ev "f" false true))
  (t/assert= (cursor) 6)
  # alt-f again: skip "world" then spaces
  (editor/handle-event (key-ev "f" false true))
  (t/assert= (cursor) 12)))

(t/test "move-word-back" (fn []
  (clear)
  (type-str "hello world foo")
  # cursor at 15 (end)
  # alt-b: back over "foo"
  (editor/handle-event (key-ev "b" false true))
  (t/assert= (cursor) 12)
  # alt-b: back over "world"
  (editor/handle-event (key-ev "b" false true))
  (t/assert= (cursor) 6)))

# ── Submit returns content and clears ──

(t/test "enter submits and clears" (fn []
  (clear)
  (type-str "hello")
  (def result (editor/handle-event (key-ev :enter)))
  (t/assert= result "hello")
  (t/assert= (content) "")
  (t/assert= (cursor) 0)))

# ── Offset->rowcol consistency ──
# We can verify cursor positioning indirectly by checking that
# after operations on multiline text, the cursor lands correctly.

(t/test "cursor position after newline and chars is sequential" (fn []
  (clear)
  (type-str "ab")
  (press-enter)
  (type-str "cd")
  # Content: "ab\ncd", cursor=5
  # Verify each position by moving left
  (t/assert= (cursor) 5)
  (press-left)
  (t/assert= (cursor) 4)
  (press-left)
  (t/assert= (cursor) 3)
  (press-left)
  (t/assert= (cursor) 2)
  (press-left)
  (t/assert= (cursor) 1)
  (press-left)
  (t/assert= (cursor) 0)
  # Can't go further left
  (press-left)
  (t/assert= (cursor) 0)))

(def pass (t/pass))
(def fail (t/fail))
