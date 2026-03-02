(import core/commands :as commands)
(import core/api :as api)

(commands/register "model"
  {:description "List available models or switch to a model"
   :usage "/model [name]"
   :function
   (fn [args]
     (def name (string/trim args))
     (if (not= name "")
       (do
         (api/set-model name)
         (string "Switched to model: " name))
       (do
         (def cfg (api/get-config))
         (def current-model (get cfg :model))
         (def models (api/list-models))
         (cond
           (nil? models)
           "Failed to fetch models. Check your API key and network connection."

           (empty? models)
           "No models returned by the API."

           (do
             (def sorted (sort-by |(get $ :id) models))
             (def lines @["Available models:"])
             (each m sorted
               (def id (get m :id))
               (def display (get m :display_name))
               (def marker (if (= id current-model) " *" ""))
               (if display
                 (array/push lines (string "  " id " — " display marker))
                 (array/push lines (string "  " id marker))))
             (array/push lines (string "\nCurrent: " current-model))
             (string/join lines "\n"))))))})
