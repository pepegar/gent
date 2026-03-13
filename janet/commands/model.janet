(import core/commands :as commands)
(import core/api :as api)

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

(defn- list-models-output []
  (def cfg (api/get-config))
  (def current-model (get cfg :model))
  (def models
    (try
      (api/list-models)
      ([err] nil)))
  (def lines @[])
  (cond
    (nil? models)
    (array/push lines "Failed to fetch models. Check your API key and network connection.")

    (empty? models)
    (array/push lines "No models returned by the API.")

    (do
      (def sorted (sort-by |(get $ :id) models))
      (array/push lines "Available models:")
      (each m sorted
        (def id (get m :id))
        (def display (get m :display_name))
        (def marker (if (= id current-model) " *" ""))
        (if display
          (array/push lines (string "  " id " — " display marker))
          (array/push lines (string "  " id marker))))))
  (array/push lines (string "\nCurrent: " current-model))
  (string/join lines "\n"))

(commands/register "model"
  {:description "List available models or switch to a model"
   :usage "/model [name]"
   :function
   (fn [args]
     (def name (string/trim args))
     (if (not= name "")
       (do
         # Auto-switch provider if we can infer it from the model name
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
       (list-models-output)))})
