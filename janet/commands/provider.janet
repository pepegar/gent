# /provider — switch between API providers

(import core/commands :as commands)
(import core/api :as api)

(commands/register "provider"
  {:description "Show or switch API provider"
   :usage "/provider [name]"
   :function
   (fn [args]
     (def name (string/trim args))
     (if (not= name "")
       (do
         (try
           (do
             (api/set-provider name)
             (def cfg (api/get-config))
             (string "Switched to provider: " name
                     "\n  model: " (get cfg :model)
                     "\n  url: " (get cfg :url)))
           ([err]
            (def providers @["anthropic" "openai"])
            (string "Error: " (string err)
                    "\nAvailable providers: " (string/join providers ", ")))))
       (do
         (def cfg (api/get-config))
         (def provider-id (api/get-active-provider-id))
         (def p (api/get-active-provider))
         (def lines @[(string "Active provider: " provider-id
                              (if p (string " (" (p :name) ")") ""))
                      (string "  model: " (get cfg :model))
                      (string "  url: " (get cfg :url))])
         (string/join lines "\n"))))})