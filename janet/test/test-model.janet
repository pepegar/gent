# Tests for /model command and api/list-models
(import core/api :as api)
(import core/commands :as commands)
(import core/selector :as selector)
(import widgets/chat :as chat)
(import test/helper :as t)
(import test/fake-http :as fake)

# Need an API key for build-headers to not throw
(os/setenv "ANTHROPIC_API_KEY" "test-key-for-model-tests")

# Import the command registration
(import commands/model)

(print "── commands/model ──")

(t/test "models-url derives from default Anthropic URL" (fn []
                                                         (api/set-url "https://api.anthropic.com/v1/messages")
                                                         (t/assert= (api/models-url) "https://api.anthropic.com/v1/models")))

(t/test "models-url derives from custom URL" (fn []
                                              (api/set-url "https://myproxy.local/v1/messages")
                                              (t/assert= (api/models-url) "https://myproxy.local/v1/models")
                                              (api/set-url "https://api.anthropic.com/v1/messages")))

(t/test "/model with arg switches model" (fn []
                                          (api/set-model "claude-sonnet-4-20250514")
                                          (def result (commands/dispatch "/model claude-opus-4-20250514"))
                                          (t/assert-truthy (get result :handled))
                                          (t/assert-truthy (string/find "Switched" (get result :result)))
                                          (def cfg (api/get-config))
                                          (t/assert= (get cfg :model) "claude-opus-4-20250514")
                                          (api/set-model "claude-sonnet-4-20250514")))

(t/test "/model with no args opens selector" (fn []
                                              (selector/reset-state)
                                              (fake/queue-request-response
                                                (json/encode @{:data @[@{:id "claude-sonnet-4-20250514"
                                                                          :display_name "Claude Sonnet 4"
                                                                          :type "model"}
                                                                       @{:id "claude-opus-4-20250514"
                                                                          :display_name "Claude Opus 4"
                                                                          :type "model"}]
                                                               :has_more false}))
                                              (def result (commands/dispatch "/model"))
                                              (t/assert-truthy (get result :handled))
                                              (t/assert= (get result :result) "")
                                              (t/assert-truthy (selector/active?))
                                              (t/assert= (length (selector/get-filtered)) 2)
                                              (t/assert= (get (selector/get-selected) :id) "claude-opus-4-20250514")
                                              (selector/close)))

(t/test "/model selector enter switches model" (fn []
                                                (selector/reset-state)
                                                (chat/reset-state)
                                                (api/set-provider "anthropic")
                                                (api/set-model "claude-sonnet-4-20250514")
                                                (fake/queue-request-response
                                                  (json/encode @{:data @[@{:id "claude-sonnet-4-20250514"
                                                                            :display_name "Claude Sonnet 4"
                                                                            :type "model"}
                                                                         @{:id "claude-opus-4-20250514"
                                                                            :display_name "Claude Opus 4"
                                                                            :type "model"}]
                                                                 :has_more false}))
                                                (commands/dispatch "/model")
                                                (selector/select-next)
                                                (selector/handle-key {:key :enter})
                                                (t/assert-falsy (selector/active?))
                                                (t/assert= (get (api/get-config) :model) "claude-sonnet-4-20250514")
                                                (t/assert-truthy
                                                  (find |(string/find "Switched to model: claude-sonnet-4-20250514" (get $ :text ""))
                                                        (chat/get-scrollback)))))

(t/test "/model with no args handles API error" (fn []
                                                 (selector/reset-state)
  # Don't queue any response — mock-request returns nil
                                                 (def result (commands/dispatch "/model"))
                                                 (t/assert-truthy (get result :handled))
                                                 (t/assert-truthy (string/find "Failed" (get result :result)))
                                                 (t/assert-falsy (selector/active?))))

(t/test "list-models handles pagination" (fn []
  # Page 1
                                          (fake/queue-request-response
                                            (json/encode @{:data @[@{:id "model-a" :type "model"}]
                                                           :has_more true
                                                           :last_id "model-a"}))
  # Page 2
                                          (fake/queue-request-response
                                            (json/encode @{:data @[@{:id "model-b" :type "model"}]
                                                           :has_more false}))
                                          (def models (api/list-models))
                                          (t/assert-truthy (not (nil? models)))
                                          (t/assert= (length models) 2)
                                          (t/assert= (get (first models) :id) "model-a")
                                          (t/assert= (get (get models 1) :id) "model-b")))

(t/test "/model gpt-5.4 auto-switches to openai provider" (fn []
  # Start on anthropic
                                                           (api/set-provider "anthropic")
                                                           (def result (commands/dispatch "/model gpt-5.4"))
                                                           (t/assert-truthy (get result :handled))
                                                           (t/assert-truthy (string/find "openai" (get result :result)))
                                                           (t/assert= (api/get-active-provider-id) "openai")
                                                           (t/assert= (get (api/get-config) :model) "gpt-5.4")
  # Reset back to anthropic
                                                           (api/set-provider "anthropic")))

(t/test "/model claude-sonnet stays on anthropic provider" (fn []
                                                            (api/set-provider "anthropic")
                                                            (def result (commands/dispatch "/model claude-sonnet-4-20250514"))
                                                            (t/assert-truthy (get result :handled))
  # Should not mention provider switch
                                                            (t/assert-falsy (string/find "switched provider" (get result :result)))
                                                            (t/assert= (api/get-active-provider-id) "anthropic")
                                                            (api/set-model "claude-sonnet-4-20250514")))

(t/test "/model claude from openai switches back to anthropic" (fn []
                                                                (api/set-provider "openai")
                                                                (def result (commands/dispatch "/model claude-sonnet-4-20250514"))
                                                                (t/assert-truthy (get result :handled))
                                                                (t/assert-truthy (string/find "anthropic" (get result :result)))
                                                                (t/assert= (api/get-active-provider-id) "anthropic")
                                                                (api/set-model "claude-sonnet-4-20250514")))

(t/test "list-models sends GET to models URL" (fn []
                                               (api/set-url "https://api.anthropic.com/v1/messages")
                                               (fake/queue-request-response
                                                 (json/encode @{:data @[@{:id "test-model" :type "model"}]
                                                                :has_more false}))
                                               (api/list-models)
                                               (def req (fake/get-last-request))
                                               (t/assert= (get req :method) "GET")
                                               (t/assert-truthy (string/find "models" (get req :url)))))
