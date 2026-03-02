# test/test-focus-grid.janet — Focus navigation in a grid layout.
#
# Verifies that widget/focus-direction navigates correctly in a 2-row layout:
#   Row 0: chat (full width)
#   Row 1: editor (left half) | filepicker (right half)

(import core/widget :as widget)
(import tui/rect)
(import test/helper :as t)

(print "── focus grid tests ──")

(defn- setup-grid []
  "Register stub widgets and lay them out as a 2-row grid."
  (each name (widget/list-widgets) (widget/unregister name))

  # Chat: full width, top row
  (widget/register @{:name :chat :state @{} :rect nil :dirty false
                      :focused false :focusable true :tasks @[] :timers @[]
                      :handle (fn [self event] nil)})

  # Editor: left half, bottom row
  (widget/register @{:name :editor :state @{} :rect nil :dirty false
                      :focused false :focusable true :tasks @[] :timers @[]
                      :handle (fn [self event] nil)})

  # Filepicker: right half, bottom row
  (widget/register @{:name :filepicker :state @{} :rect nil :dirty false
                      :focused false :focusable true :tasks @[] :timers @[]
                      :handle (fn [self event] nil)})

  # Layout: 80x24, chat gets rows 0-20, bottom row (21-23) splits 40+40
  (widget/set-layout-fn
    (fn [area]
      @{:chat (rect/rect 0 0 80 21)
        :editor (rect/rect 0 21 40 3)
        :filepicker (rect/rect 40 21 40 3)}))
  (widget/do-layout (rect/rect 0 0 80 24)))

# ── Horizontal navigation (same row) ─────────────────────────

(t/test "focus-direction: editor → right → filepicker" (fn []
  (setup-grid)
  (widget/focus :editor)
  (def result (widget/focus-direction :right))
  (t/assert= result :filepicker)
  (t/assert-truthy ((widget/get-widget :filepicker) :focused))
  (t/assert-falsy ((widget/get-widget :editor) :focused))))

(t/test "focus-direction: filepicker → left → editor" (fn []
  (setup-grid)
  (widget/focus :filepicker)
  (def result (widget/focus-direction :left))
  (t/assert= result :editor)
  (t/assert-truthy ((widget/get-widget :editor) :focused))))

# ── Vertical navigation (between rows) ───────────────────────

(t/test "focus-direction: editor → up → chat" (fn []
  (setup-grid)
  (widget/focus :editor)
  (def result (widget/focus-direction :up))
  (t/assert= result :chat)
  (t/assert-truthy ((widget/get-widget :chat) :focused))))

(t/test "focus-direction: filepicker → up → chat" (fn []
  (setup-grid)
  (widget/focus :filepicker)
  (def result (widget/focus-direction :up))
  (t/assert= result :chat)
  (t/assert-truthy ((widget/get-widget :chat) :focused))))

(t/test "focus-direction: chat → down → editor or filepicker" (fn []
  (setup-grid)
  (widget/focus :chat)
  (def result (widget/focus-direction :down))
  # Chat overlaps both editor and filepicker horizontally,
  # so it should go to the closest one (editor, since it starts at x=0)
  (t/assert-truthy (or (= result :editor) (= result :filepicker)))))

# ── Toroidal wrap (stays in same row/column) ─────────────────

(t/test "focus-direction: filepicker → right wraps to editor (same row)" (fn []
  (setup-grid)
  (widget/focus :filepicker)
  (def result (widget/focus-direction :right))
  # Wraps to leftmost widget in same row, not chat
  (t/assert= result :editor)))

(t/test "focus-direction: editor → left wraps to filepicker (same row)" (fn []
  (setup-grid)
  (widget/focus :editor)
  (def result (widget/focus-direction :left))
  # Wraps to rightmost widget in same row, not chat
  (t/assert= result :filepicker)))

(t/test "focus-direction: chat → up wraps to chat (only widget in column)" (fn []
  (setup-grid)
  (widget/focus :chat)
  (def result (widget/focus-direction :up))
  # Chat is full-width, wraps to bottom row widgets that overlap horizontally
  (t/assert-truthy (or (= result :editor) (= result :filepicker)))))

(t/test "focus-direction: chat → left stays nil (only widget in row)" (fn []
  (setup-grid)
  (widget/focus :chat)
  (def result (widget/focus-direction :left))
  # No other widget in chat's row, no vertical overlap → nil
  (t/assert-falsy result)))

(t/test "focus-direction: chat → right stays nil (only widget in row)" (fn []
  (setup-grid)
  (widget/focus :chat)
  (def result (widget/focus-direction :right))
  (t/assert-falsy result)))

# ── Non-focusable widgets are skipped ────────────────────────

(t/test "focus-direction skips non-focusable separator" (fn []
  (each name (widget/list-widgets) (widget/unregister name))

  (widget/register @{:name :chat :state @{} :rect nil :dirty false
                      :focused false :focusable true :tasks @[] :timers @[]
                      :handle (fn [self event] nil)})
  (widget/register @{:name :separator :state @{} :rect nil :dirty false
                      :focused false :focusable false :tasks @[] :timers @[]
                      :handle (fn [self event] nil)})
  (widget/register @{:name :editor :state @{} :rect nil :dirty false
                      :focused false :focusable true :tasks @[] :timers @[]
                      :handle (fn [self event] nil)})

  (widget/set-layout-fn
    (fn [area]
      @{:chat (rect/rect 0 0 80 20)
        :separator (rect/rect 0 20 80 1)
        :editor (rect/rect 0 21 80 3)}))
  (widget/do-layout (rect/rect 0 0 80 24))

  (widget/focus :editor)
  (def result (widget/focus-direction :up))
  # Should skip separator (focusable=false) and go to chat
  (t/assert= result :chat)))

# ── Round-trip ───────────────────────────────────────────────

(t/test "focus round-trip: editor → filepicker → chat → editor" (fn []
  (setup-grid)
  (widget/focus :editor)

  # Right → filepicker
  (widget/focus-direction :right)
  (t/assert-truthy ((widget/get-widget :filepicker) :focused))

  # Up → chat
  (widget/focus-direction :up)
  (t/assert-truthy ((widget/get-widget :chat) :focused))

  # Down → back to bottom row
  (def result (widget/focus-direction :down))
  (t/assert-truthy (or (= result :editor) (= result :filepicker)))))

(def pass (t/pass))
(def fail (t/fail))
