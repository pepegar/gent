# test/test-filepicker.janet — Tests for the filepicker widget.
#
# Tests rendering, navigation, and the configurable API.

(import test/fake-http :as fake)
(fake/install (curenv))

(import widgets/filepicker :as fp)
(import core/widget :as widget)
(import tui)
(import test/helper :as t)

(print "── filepicker tests ──")

# ── Helpers ────────────────────────────────────────────────────

(defn- setup [&opt width height &named source title name on-enter]
  "Set up a filepicker widget with a fixed-size viewport."
  (default width 30)
  (default height 8)
  (default source (fn [] @["a.txt" "b.txt" "c.txt"]))
  (each n (widget/list-widgets) (widget/unregister n))
  (def w (fp/create :source source
                     :title (or title "Files")
                     :name (or name :filepicker)
                     :on-enter on-enter))
  (widget/register w)
  (def r (tui/rect 0 0 width height))
  (widget/set-layout-fn (fn [a] @{(w :name) r}))
  (widget/do-layout (tui/rect 0 0 width height))
  w)

(defn- render-fp [w &opt width height]
  "Render the filepicker widget and return plain text rows."
  (default width 30)
  (default height 8)
  (def r (tui/rect 0 0 width height))
  (def buf (tui/buffer r))
  ((w :render) w r buf)
  (tui/buffer-to-plain-rows buf))

(defn- any-row-contains? [rows text]
  (some |(not (nil? (string/find text $))) rows))

# ── Rendering tests ──────────────────────────────────────────

(t/test "filepicker: renders border with title" (fn []
  (def w (setup 30 8))
  (def rows (render-fp w))
  (t/assert-truthy (any-row-contains? rows "Files"))))

(t/test "filepicker: custom title appears in border" (fn []
  (def w (setup 30 8 :title "Git Status"))
  (def rows (render-fp w))
  (t/assert-truthy (any-row-contains? rows "Git Status"))))

(t/test "filepicker: shows items from source" (fn []
  (def w (setup 30 8 :source (fn [] @["README.md" "Cargo.toml" "src"])))
  (def rows (render-fp w))
  (t/assert-truthy (any-row-contains? rows "README.md"))
  (t/assert-truthy (any-row-contains? rows "Cargo.toml"))
  (t/assert-truthy (any-row-contains? rows "src"))))

(t/test "filepicker: empty source renders cleanly" (fn []
  (def w (setup 30 8 :source (fn [] @[])))
  (def rows (render-fp w))
  (t/assert-truthy (any-row-contains? rows "Files"))))

# ── Custom name ──────────────────────────────────────────────

(t/test "filepicker: custom name is set" (fn []
  (def w (setup 30 8 :name :git-status))
  (t/assert= (w :name) :git-status)))

# ── Navigation tests ─────────────────────────────────────────

(t/test "filepicker: down moves selection" (fn []
  (def w (setup 30 8))
  (t/assert= ((w :state) :selected) 0)
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 1)
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 2)))

(t/test "filepicker: down wraps around" (fn []
  (def w (setup 30 8 :source (fn [] @["a.txt" "b.txt"])))
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 1)
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 0)))

(t/test "filepicker: up moves selection backward" (fn []
  (def w (setup 30 8))
  (put (w :state) :selected 2)
  ((w :handle) w {:type :key :key :up :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 1)))

(t/test "filepicker: up wraps around" (fn []
  (def w (setup 30 8))
  (t/assert= ((w :state) :selected) 0)
  ((w :handle) w {:type :key :key :up :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 2)))

# ── Scroll offset follows selection on wrap ───────────────────

(t/test "filepicker: down wrap scrolls to top" (fn []
  # 10 items, viewport inner height = 4 (height 6 minus 2 for border)
  (def items (map |(string "file" $ ".txt") (range 10)))
  (def w (setup 30 6 :source (fn [] items)))
  # Move to last item
  (put (w :state) :selected 9)
  (put (w :state) :scroll-offset 6)
  # Down wraps to 0
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 0)
  (t/assert= ((w :state) :scroll-offset) 0)))

(t/test "filepicker: up wrap scrolls to bottom" (fn []
  (def items (map |(string "file" $ ".txt") (range 10)))
  (def w (setup 30 6 :source (fn [] items)))
  # At top, scroll-offset 0
  (t/assert= ((w :state) :selected) 0)
  (t/assert= ((w :state) :scroll-offset) 0)
  # Up wraps to last item (9)
  ((w :handle) w {:type :key :key :up :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 9)
  # scroll-offset should show item 9 (offset = 9 - 4 + 1 = 6)
  (t/assert= ((w :state) :scroll-offset) 6)))

# ── Enter calls on-enter ─────────────────────────────────────

(t/test "filepicker: enter calls on-enter with selected item" (fn []
  (var received nil)
  (def w (setup 30 8
    :source (fn [] @["first.txt" "second.txt"])
    :on-enter (fn [item] (set received item))))
  # Select second item
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  ((w :handle) w {:type :key :key :enter :alt false :ctrl false :shift false})
  (t/assert= received "second.txt")))

(t/test "filepicker: default on-enter publishes :file-opened" (fn []
  (def w (setup 30 8 :source (fn [] @["test-file.txt"])))
  (var received nil)
  (widget/subscribe :file-opened (fn [data] (set received data)))
  ((w :handle) w {:type :key :key :enter :alt false :ctrl false :shift false})
  (t/assert-truthy received)
  (t/assert= (received :path) "test-file.txt")))

# ── String source ────────────────────────────────────────────

(t/test "filepicker: string source runs shell command" (fn []
  (fake/set-process-handler
    (fn [cmd args]
      @{:stdout "foo\nbar\nbaz\n" :stderr "" :status 0}))
  (def w (fp/create :source "echo foo"))
  (def files ((w :state) :files))
  (fake/set-process-handler nil)
  (t/assert= (length files) 3)
  (t/assert= (get files 0) "foo")
  (t/assert= (get files 1) "bar")
  (t/assert= (get files 2) "baz")))

# ── Empty list ignores navigation ────────────────────────────

(t/test "filepicker: navigation on empty list does nothing" (fn []
  (def w (setup 30 8 :source (fn [] @[])))
  ((w :handle) w {:type :key :key :down :alt false :ctrl false :shift false})
  (t/assert= ((w :state) :selected) 0)
  ((w :handle) w {:type :key :key :enter :alt false :ctrl false :shift false})
  (t/assert-truthy true)))

(def pass (t/pass))
(def fail (t/fail))
