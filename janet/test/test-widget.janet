# Tests for core/widget
(import core/widget :as widget)
(import tui/rect)
(import test/helper :as t)

(print "── core/widget ──")

# Clean slate before each test suite
(each name (widget/list-widgets)
  (widget/unregister name))

(t/test "register and get-widget" (fn []
                                   (def w @{:name :test-w :state @{} :rect nil :dirty false
                                             :focused false :tasks @[] :timers @[]
                                             :handle nil :render nil})
                                   (widget/register w)
                                   (t/assert-truthy (widget/get-widget :test-w))
                                   (t/assert= ((widget/get-widget :test-w) :name) :test-w)
                                   (widget/unregister :test-w)))

(t/test "unregister removes widget" (fn []
                                     (widget/register @{:name :temp :state @{} :rect nil :dirty false
                                                         :focused false :tasks @[] :timers @[]})
                                     (widget/unregister :temp)
                                     (t/assert-falsy (widget/get-widget :temp))))

(t/test "list-widgets returns names in order" (fn []
                                               (widget/register @{:name :aaa :state @{} :rect nil :dirty false
                                                                   :focused false :tasks @[] :timers @[]})
                                               (widget/register @{:name :bbb :state @{} :rect nil :dirty false
                                                                   :focused false :tasks @[] :timers @[]})
                                               (def names (widget/list-widgets))
                                               (t/assert-truthy (find |(= $ :aaa) names))
                                               (t/assert-truthy (find |(= $ :bbb) names))
                                               (widget/unregister :aaa)
                                               (widget/unregister :bbb)))

(t/test "focus sets focused flag" (fn []
                                   (widget/register @{:name :focus-a :state @{} :rect nil :dirty false
                                                       :focused false :tasks @[] :timers @[]})
                                   (widget/register @{:name :focus-b :state @{} :rect nil :dirty false
                                                       :focused false :tasks @[] :timers @[]})
                                   (widget/focus :focus-a)
                                   (t/assert-truthy ((widget/get-widget :focus-a) :focused))
                                   (t/assert-falsy ((widget/get-widget :focus-b) :focused))
                                   (widget/focus :focus-b)
                                   (t/assert-falsy ((widget/get-widget :focus-a) :focused))
                                   (t/assert-truthy ((widget/get-widget :focus-b) :focused))
                                   (widget/unregister :focus-a)
                                   (widget/unregister :focus-b)))

(t/test "mark-dirty and mark-all-dirty" (fn []
                                         (widget/register @{:name :d1 :state @{} :rect nil :dirty false
                                                             :focused false :tasks @[] :timers @[]})
                                         (widget/register @{:name :d2 :state @{} :rect nil :dirty false
                                                             :focused false :tasks @[] :timers @[]})
                                         (widget/mark-dirty :d1)
                                         (t/assert-truthy ((widget/get-widget :d1) :dirty))
                                         (t/assert-falsy ((widget/get-widget :d2) :dirty))
                                         (widget/mark-all-dirty)
                                         (t/assert-truthy ((widget/get-widget :d2) :dirty))
                                         (widget/unregister :d1)
                                         (widget/unregister :d2)))

(t/test "dispatch calls handle and returns value" (fn []
                                                   (widget/register @{:name :disp :state @{} :rect nil :dirty false
                                                                       :focused false :tasks @[] :timers @[]
                                                                       :handle (fn [self event] (string "got:" (event :data)))})
                                                   (def result (widget/dispatch :disp {:data "hello"}))
                                                   (t/assert= result "got:hello")
                                                   (widget/unregister :disp)))

(t/test "do-layout assigns rects" (fn []
                                   (widget/register @{:name :lay1 :state @{} :rect nil :dirty false
                                                       :focused false :tasks @[] :timers @[]})
                                   (widget/register @{:name :lay2 :state @{} :rect nil :dirty false
                                                       :focused false :tasks @[] :timers @[]})
                                   (widget/set-layout-fn
                                     (fn [area]
                                       @{:lay1 (rect/rect 0 0 80 12)
                                         :lay2 (rect/rect 0 12 80 12)}))
                                   (widget/do-layout (rect/rect 0 0 80 24))
                                   (t/assert= (get-in (widget/get-widget :lay1) [:rect :height]) 12)
                                   (t/assert= (get-in (widget/get-widget :lay2) [:rect :y]) 12)
                                   (widget/unregister :lay1)
                                   (widget/unregister :lay2)))

(t/test "update-all calls :update" (fn []
                                    (var called false)
                                    (widget/register @{:name :upd :state @{} :rect nil :dirty false
                                                        :focused false :tasks @[] :timers @[]
                                                        :update (fn [self] (set called true))})
                                    (widget/update-all)
                                    (t/assert-truthy called)
                                    (widget/unregister :upd)))

(def pass (t/pass))
(def fail (t/fail))
