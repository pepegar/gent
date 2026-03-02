# Test editor widget scroll behavior
(import widgets/editor :as editor)
(import core/widget :as widget)
(import core/input-history :as ih)
(import widgets/editor_new :as ed)
(import core/buffers :as buffers)
(import test/helper :as t)

(print "── widgets/editor (scroll behavior) ──")

# Clear any existing widgets before starting
(each name (widget/list-widgets)
  (widget/unregister name))

(t/test "arrow up with empty editor enters history" (fn []
  # Create and register editor widget
                                                    (def w (editor/create))
                                                    (widget/register w)

  # Setup: put some text in input history
                                                    (ih/clear)
                                                    (ih/push "previous command")
                                                    (ih/reset)  # Reset browsing state

  # Editor starts empty, cursor at position 0
  # Arrow up should enter history
                                                    (def result (widget/dispatch :editor {:type :key :key :up}))
                                                    (t/assert= result nil)

  # Editor text should now contain the previous command
                                                    (def editor-state (editor/get-editor-state))
                                                    (t/assert= (ed/text editor-state) "previous command")

  # Clean up
                                                    (widget/unregister :editor)))

(t/test "arrow up at top with text but not browsing moves to line start" (fn []
  # Create and register editor widget
                                                                            (def w (editor/create))
                                                                            (widget/register w)

  # Setup: put some text in input history
                                                                            (ih/clear)
                                                                            (ih/push "previous command")
                                                                            (ih/reset)  # Reset browsing state

  # Put text in editor
                                                                            (def editor-state (editor/get-editor-state))
                                                                            (ed/set-text editor-state "hello")
                                                                            (ed/move-line-end editor-state)  # Move to end

  # Arrow up at first line should move to line start (not enter history)
                                                                            (def result (widget/dispatch :editor {:type :key :key :up}))
                                                                            (t/assert= result nil)

  # Text should be unchanged
                                                                            (t/assert= (ed/text editor-state) "hello")

  # Cursor should be at start
                                                                            (t/assert= (ed/point editor-state) 0)

  # Clean up
                                                                            (widget/unregister :editor)))

(t/test "arrow up at top with text and browsing enters history" (fn []
  # Create and register editor widget
                                                                (def w (editor/create))
                                                                (widget/register w)

  # Setup: put multiple commands in history
                                                                (ih/clear)
                                                                (ih/push "command 1")
                                                                (ih/push "command 2")
                                                                (ih/reset)

  # First up from empty editor → enters history with command 2
                                                                (widget/dispatch :editor {:type :key :key :up})
                                                                (def editor-state (editor/get-editor-state))
                                                                (t/assert= (ed/text editor-state) "command 2")

  # Now at first line and browsing → second up should get command 1
                                                                (widget/dispatch :editor {:type :key :key :up})
                                                                (t/assert= (ed/text editor-state) "command 1")

  # Clean up
                                                                (widget/unregister :editor)))

(t/test "arrow down navigates input history forward when browsing" (fn []
  # Create and register editor widget
                                                                  (def w (editor/create))
                                                                  (widget/register w)

  # Setup: put multiple commands in input history
                                                                  (ih/clear)
                                                                  (ih/push "command 1")
                                                                  (ih/push "command 2")
                                                                  (ih/reset)

  # First up to start browsing (gets command 2)
                                                                  (widget/dispatch :editor {:type :key :key :up})

  # Second up to get command 1
                                                                  (widget/dispatch :editor {:type :key :key :up})

  # Now down should go back to command 2
                                                                  (def result (widget/dispatch :editor {:type :key :key :down}))
                                                                  (t/assert= result nil)  # Internal handling

  # Editor should now show command 2
                                                                  (def editor-state (editor/get-editor-state))
                                                                  (t/assert= (ed/text editor-state) "command 2")

  # Clean up
                                                                  (widget/unregister :editor)))

(t/test "arrow down at bottom with text but not browsing moves to line end" (fn []
  # Create and register editor widget
                                                                              (def w (editor/create))
                                                                              (widget/register w)

  # Setup: put some text in history
                                                                              (ih/clear)
                                                                              (ih/push "previous command")
                                                                              (ih/reset)

  # Put text in editor
                                                                              (def editor-state (editor/get-editor-state))
                                                                              (ed/set-text editor-state "hello")
                                                                              (buffers/set-point (editor-state :buf) 0)  # Move to start

  # Arrow down at last line should move to line end (not enter history)
                                                                              (def result (widget/dispatch :editor {:type :key :key :down}))
                                                                              (t/assert= result nil)

  # Text should be unchanged
                                                                              (t/assert= (ed/text editor-state) "hello")

  # Cursor should be at end
                                                                              (t/assert= (ed/point editor-state) 5)

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

  # Arrow up should move cursor up within the text
                                                                    (def result (widget/dispatch :editor {:type :key :key :up}))
                                                                    (t/assert= result nil)

  # Cursor should have moved up to line 2
                                                                    (def vis-pos-after (ed/point->visual editor-state))
                                                                    (t/assert= (vis-pos-after :row) 1)  # Should be on line 2 (0-indexed)

  # Clean up
                                                                    (widget/unregister :editor)))

(def pass (t/pass))
(def fail (t/fail))
