# Test editor widget scroll behavior
(import widgets/editor :as editor)
(import core/widget :as widget)
(import core/input-history :as ih)
(import widgets/editor_new :as ed)
(import test/helper :as t)

(print "── widgets/editor (scroll behavior) ──")

# Clear any existing widgets before starting
(each name (widget/list-widgets)
  (widget/unregister name))

(t/test "arrow up at top boundary scrolls chat instead of input history" (fn []
  # Create and register editor widget  
                                                                          (def w (editor/create))
                                                                          (widget/register w)
  
  # Setup: put some text in input history
                                                                          (ih/clear)
                                                                          (ih/push "previous command")
                                                                          (ih/reset)  # Reset browsing state
  
  # Editor starts empty, cursor at position 0 (top row)
  # Arrow up should return :scroll-line-up instead of using input history
                                                                          (def result (widget/dispatch :editor {:type :key :key :up}))
                                                                          (t/assert= result :scroll-line-up)
  
  # Editor text should still be empty (no input history used)
                                                                          (def editor-state (editor/get-editor-state))
                                                                          (t/assert= (ed/text editor-state) "")
  
  # Clean up
                                                                          (widget/unregister :editor)))

(t/test "arrow down at bottom boundary scrolls chat instead of input history" (fn []
  # Create and register editor widget
                                                                               (def w (editor/create))
                                                                               (widget/register w)
  
  # Setup: put some text in input history but don't start browsing
                                                                               (ih/clear)
                                                                               (ih/push "previous command")  
                                                                               (ih/reset)  # Reset browsing state
  
  # Editor starts empty, cursor at bottom row
  # Arrow down should return :scroll-line-down
                                                                               (def result (widget/dispatch :editor {:type :key :key :down}))
                                                                               (t/assert= result :scroll-line-down)
  
  # Editor text should still be empty
                                                                               (def editor-state (editor/get-editor-state))
                                                                               (t/assert= (ed/text editor-state) "")
  
  # Clean up
                                                                               (widget/unregister :editor)))

(t/test "ctrl+up uses input history" (fn []
  # Create and register editor widget
                                      (def w (editor/create))
                                      (widget/register w)
  
  # Setup: put some text in input history
                                      (ih/clear)
                                      (ih/push "previous command")
                                      (ih/reset)  # Reset browsing state
  
  # Ctrl+Up should use input history
                                      (def result (widget/dispatch :editor {:type :key :key :up :ctrl true}))
                                      (t/assert= result nil)  # Internal handling, no scroll signal
  
  # Editor text should now contain the previous command
                                      (def editor-state (editor/get-editor-state))
                                      (t/assert= (ed/text editor-state) "previous command")
  
  # Clean up
                                      (widget/unregister :editor)))

(t/test "ctrl+down navigates input history when browsing" (fn []
  # Create and register editor widget
                                                           (def w (editor/create))
                                                           (widget/register w)
  
  # Setup: put multiple commands in input history
                                                           (ih/clear)
                                                           (ih/push "command 1")
                                                           (ih/push "command 2")  
                                                           (ih/reset)
  
  # First Ctrl+Up to start browsing (gets command 2)
                                                           (widget/dispatch :editor {:type :key :key :up :ctrl true})
  
  # Second Ctrl+Up to get command 1
                                                           (widget/dispatch :editor {:type :key :key :up :ctrl true})
  
  # Now Ctrl+Down should go back to command 2
                                                           (def result (widget/dispatch :editor {:type :key :key :down :ctrl true}))
                                                           (t/assert= result nil)  # Internal handling
  
  # Editor should now show command 2
                                                           (def editor-state (editor/get-editor-state))
                                                           (t/assert= (ed/text editor-state) "command 2")
  
  # Clean up
                                                           (widget/unregister :editor)))

(t/test "arrow keys within multi-line editor move cursor normally" (fn []
  # Create and register editor widget
                                                                    (def w (editor/create))
                                                                    (widget/register w)
  
  # Insert multi-line text
                                                                    (def editor-state (editor/get-editor-state))
                                                                    (ed/set-text editor-state "line 1\nline 2\nline 3")
                                                                    (ed/move-line-end editor-state)  # Move to end of last line
  
  # Arrow up should move cursor up within the text (not scroll)
                                                                    (def result (widget/dispatch :editor {:type :key :key :up}))
                                                                    (t/assert= result nil)  # No scroll signal
  
  # Cursor should have moved up to line 2
                                                                    (def vis-pos-after (ed/point->visual editor-state))
                                                                    (t/assert= (vis-pos-after :row) 1)  # Should be on line 2 (0-indexed)
  
  # Clean up
                                                                    (widget/unregister :editor)))

(def pass (t/pass))
(def fail (t/fail))
