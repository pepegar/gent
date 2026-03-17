# /provider — switch between API providers

(import core/commands :as commands)
(import core/api :as api)
(import core/selector :as selector)

(defn- switch-provider [name]
  (api/set-provider name)
  (def cfg (api/get-config))
  (string "Switched to provider: " name
          "\n  model: " (get cfg :model)
          "\n  url: " (get cfg :url)))

(defn- open-provider-selector []
  (def current-provider (api/get-active-provider-id))
  (selector/open
    {:title "Providers"
     :items
     (map (fn [provider]
            (def id (provider :id))
            (def name (provider :name))
            @{:id id
              :label id
              :detail (string name " · " (provider :default-model))
              :search-text (string id " " name " " (provider :default-model))
              :current (= id current-provider)})
          (api/list-providers))
     :empty-text "No providers available."
     :on-submit (fn [item] (switch-provider (item :id)))})
  "")

(commands/register "provider"
  {:description "Show or switch API provider"
   :usage "/provider [name]"
   :function
   (fn [args]
     (def name (string/trim args))
     (if (not= name "")
       (do
         (try
           (switch-provider name)
           ([err]
            (def providers (map |($ :id) (api/list-providers)))
            (string "Error: " (string err)
                    "\nAvailable providers: " (string/join providers ", ")))))
       (open-provider-selector)))})
