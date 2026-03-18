(import core/commands :as commands)
(import core/api :as api)
(import core/selector :as selector)
(import widgets/chat :as chat)

(defn- infer-provider
  "Infer the provider ID from a model name. Returns nil if unknown."
  [model-name]
  (cond
    (string/has-prefix? "gpt-" model-name) "openai"
    (string/has-prefix? "o1" model-name) "openai"
    (string/has-prefix? "o3" model-name) "openai"
    (string/has-prefix? "o4" model-name) "openai"
    (string/has-prefix? "claude-" model-name) "anthropic"
    nil))

(defn- switch-model [name]
  # Auto-switch provider if we can infer it from the model name.
  (def target-provider (infer-provider name))
  (def current-provider (api/get-active-provider-id))
  (when (and target-provider (not= target-provider current-provider))
    (api/set-provider target-provider))
  (api/set-model name)
  (def switched-msg
    (if (and target-provider (not= target-provider current-provider))
      (string " (switched provider to " target-provider ")")
      ""))
  (string "Switched to model: " name switched-msg))

(defn- open-model-selector []
  (def cfg (api/get-config))
  (def current-model (get cfg :model))
  (def models
    (try
      (api/list-models)
      ([err] nil)))
  (cond
    (nil? models)
    "Failed to fetch models. Check your API key and network connection."

    (empty? models)
    "No models returned by the API."

    (do
      (def sorted (sort-by |(get $ :id) models))
      (selector/open
        {:title "Models"
         :items
         (map (fn [m]
                (def id (get m :id))
                (def display (get m :display_name))
                @{:id id
                  :label id
                  :detail display
                  :search-text (if display (string id " " display) id)
                  :current (= id current-model)})
              sorted)
         :empty-text "No models found."
         :on-submit
         (fn [item]
           (chat/output (switch-model (item :id))))})
      "")))

(commands/register "model"
  {:description "List available models or switch to a model"
   :usage "/model [name]"
   :function
   (fn [args]
     (def name (string/trim args))
     (if (not= name "")
       (switch-model name)
       (open-model-selector)))})
