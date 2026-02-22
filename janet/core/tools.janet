# Tool registry — the heart of extensibility.
# Tools are Janet tables with :name, :description, :schema, :function.
# The LLM can create new tools at runtime via eval-janet.

(import core/hooks :as hooks)
(import core/abort :as abort)

(var- registry @{})

(defn register
  "Register a tool definition. Can be called from tool scripts or by the LLM."
  [name definition]
  (put registry name definition)
  (string "Tool registered: " name))

(defn definitions
  "Return tool definitions formatted for the Anthropic API."
  []
  (seq [[name tool] :pairs registry]
    {:name name
     :description (tool :description)
     :input_schema (tool :schema)}))

(defn dispatch
  "Execute a tool by name with the given input table.
   Fires :before-tool-call and :after-tool-call hooks.
   Checks the abort flag before execution — returns early if aborted.
   Returns a string (for text results) or a table/array (for structured content like images)."
  [name input]
  # Check abort flag before executing
  (when (abort/aborted?)
    (break "Aborted"))
  (if-let [tool (get registry name)]
    (do
      (hooks/run :before-tool-call name input)
      (try
        (let [result ((tool :function) input)]
          (def coerced
            (cond
              # Structured content (image blocks, etc.) — pass through as-is
              (table? result)  result
              (tuple? result)  result
              (array? result)  result
              # Everything else — coerce to string
              (string result)))
          (hooks/run :after-tool-call name input coerced)
          coerced)
        ([err]
          (def errmsg (string "Error executing " name ": " err))
          (hooks/run :on-error err)
          errmsg)))
    (string "Unknown tool: " name)))

(defn get-tool
  "Get a tool definition by name, or nil."
  [name]
  (get registry name))

(defn list-registered
  "Return a list of registered tool names."
  []
  (keys registry))

(defn async?
  "Check if a tool result is an async handle (has :type :async)."
  [result]
  (and (table? result) (= :async (get result :type))))

(defn async-tool
  "Create an async tool handle. The agent loop will poll this instead of
   blocking on the result.

   Returns a table:
     :type    — :async (marker)
     :poll    — (fn [] ...) non-blocking poll. Returns:
                  - nil: not ready yet
                  - [:done result]: tool completed with result
                  - [:error msg]: tool failed
     :cancel  — (fn [] ...) cancel the tool execution"
  [poll-fn cancel-fn]
  @{:type :async
    :poll poll-fn
    :cancel cancel-fn})
