# Tests for /provider command
(import core/api :as api)
(import core/commands :as commands)
(import core/selector :as selector)
(import test/helper :as t)

# Import the command registration
(import commands/provider)

(print "── commands/provider ──")

(t/test "/provider with arg switches provider" (fn []
                                                (api/set-provider "anthropic")
                                                (def result (commands/dispatch "/provider openai"))
                                                (t/assert-truthy (get result :handled))
                                                (t/assert-truthy (string/find "Switched to provider: openai" (get result :result)))
                                                (t/assert= (api/get-active-provider-id) "openai")
                                                (api/set-provider "anthropic")))

(t/test "/provider with no args opens selector" (fn []
                                                  (selector/reset-state)
                                                  (api/set-provider "anthropic")
                                                  (def result (commands/dispatch "/provider"))
                                                  (t/assert-truthy (get result :handled))
                                                  (t/assert= (get result :result) "")
                                                  (t/assert-truthy (selector/active?))
                                                  (t/assert= (length (selector/get-filtered)) 2)
                                                  (t/assert= (get (selector/get-selected) :id) "anthropic")
                                                  (selector/close)))

(t/test "/provider selector enter switches provider" (fn []
                                                       (selector/reset-state)
                                                       (api/set-provider "anthropic")
                                                       (commands/dispatch "/provider")
                                                       (selector/select-next)
                                                       (selector/handle-key {:key :enter})
                                                       (t/assert-falsy (selector/active?))
                                                       (t/assert= (api/get-active-provider-id) "openai")
                                                       (api/set-provider "anthropic")))

(t/test "/provider invalid arg lists available providers" (fn []
                                                           (def result (commands/dispatch "/provider nope"))
                                                           (t/assert-truthy (get result :handled))
                                                           (t/assert-truthy (string/find "Available providers: anthropic, openai"
                                                                                         (get result :result)))))
