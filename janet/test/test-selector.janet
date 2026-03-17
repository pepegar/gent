# Tests for core/selector overlay
(import core/selector :as selector)
(import test/helper :as t)
(import tui)

(print "── core/selector ──")

(defn- sample-items []
  @[@{:id "alpha" :label "alpha" :detail "First"}
    @{:id "beta" :label "beta" :detail "Second" :current true}
    @{:id "gamma" :label "gamma" :detail "Third"}])

(t/test "selector is initially idle" (fn []
                                      (selector/reset-state)
                                      (t/assert-falsy (selector/active?))))

(t/test "selector open activates and exposes items" (fn []
                                                     (selector/reset-state)
                                                     (selector/open {:title "Test" :items (sample-items)})
                                                     (t/assert-truthy (selector/active?))
                                                     (t/assert= (length (selector/get-filtered)) 3)
                                                     (t/assert= (get (selector/get-selected) :id) "alpha")
                                                     (selector/close)))

(t/test "selector search filters items" (fn []
                                         (selector/reset-state)
                                         (selector/open {:title "Test" :items (sample-items)})
                                         (selector/search-insert "g")
                                         (selector/search-insert "a")
                                         (selector/search-insert "m")
                                         (t/assert= (selector/get-query) "gam")
                                         (t/assert= (length (selector/get-filtered)) 1)
                                         (t/assert= (get (selector/get-selected) :id) "gamma")
                                         (selector/close)))

(t/test "selector enter invokes callback and closes" (fn []
                                                      (selector/reset-state)
                                                      (var picked nil)
                                                      (selector/open {:title "Test"
                                                                      :items (sample-items)
                                                                      :on-submit (fn [item] (set picked (item :id)))})
                                                      (selector/select-next)
                                                      (selector/handle-key {:key :enter})
                                                      (t/assert-falsy (selector/active?))
                                                      (t/assert= picked "beta")))

(t/test "selector renders popup" (fn []
                                  (selector/reset-state)
                                  (selector/open {:title "Test" :items (sample-items)})
                                  (def popup (selector/render-overlay (tui/rect 0 0 100 30)))
                                  (t/assert-truthy popup)
                                  (t/assert-truthy (> (length (popup :cells)) 0))
                                  (t/assert-truthy (> (popup :width) 0))
                                  (t/assert-truthy (> (popup :height) 0))
                                  (selector/close)))
