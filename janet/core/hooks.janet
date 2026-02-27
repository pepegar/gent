# Hooks — extensibility points for the agent.
# Like Emacs hooks: arrays of functions keyed by event name.
# Users add functions via (hooks/add :event-name fn), and
# the agent core fires them at the right time.
#
# Supported hooks:
#   :before-tool-call  (fn [name input])         — called before dispatching a tool
#   :after-tool-call   (fn [name input result])   — called after a tool returns
#   :render-tool-call  (fn [name input])          — custom tool call rendering; return truthy to suppress default
#   :render-tool-result (fn [name result])        — custom tool result rendering; return truthy to suppress default
#   :before-send       (fn [conversation])         — called before API call, can mutate conversation
#   :after-response    (fn [response])             — called after API response received
#   :on-error          (fn [err])                  — called on errors
#   :after-message     (fn [msg])                  — called after any message is pushed to conversation
#   :conversation-clear                            — called when conversation is cleared
#   :conversation-rollback (fn [n])                — called after rolling back n messages
#   :session-resume    (fn [session-id])           — called after resuming a session
#   :session-fork      (fn [old-id new-id])        — called after forking a session

(var- hooks @{})

(defn add
  "Add a function to a hook. Hook is created if it doesn't exist."
  [event f]
  (unless (get hooks event)
    (put hooks event @[]))
  (array/push (get hooks event) f)
  (string "Hook added: " event))

(defn remove
  "Remove a specific function from a hook."
  [event f]
  (when-let [fns (get hooks event)]
    (var idx nil)
    (for i 0 (length fns)
      (when (= (get fns i) f)
        (set idx i)))
    (when idx
      (array/remove fns idx)
      true)))

(defn clear
  "Remove all functions from a hook."
  [event]
  (put hooks event @[])
  (string "Hook cleared: " event))

(defn list-hooks
  "Return all hook names that have registered functions."
  []
  (seq [[k v] :pairs hooks :when (not (empty? v))] k))

(defn list-functions
  "Return the array of functions for a hook."
  [event]
  (get hooks event @[]))

(defn run
  "Fire all functions registered on a hook with the given args.
   Returns the last non-nil return value (useful for transformation hooks).
   If a hook function errors, the error is caught and printed but doesn't stop other hooks."
  [event & args]
  (var last-result nil)
  (when-let [fns (get hooks event)]
    (each f fns
      (try
        (do
          (def result (apply f args))
          (when (not (nil? result))
            (set last-result result)))
        ([err]
         (eprintf "Hook error in %s: %s" (string event) (string err))))))
  last-result)
