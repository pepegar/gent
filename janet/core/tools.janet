# Tool registry — the heart of extensibility.
# Tools are Janet tables with :name, :description, :schema, :function.
# The LLM can create new tools at runtime via eval-janet.

(import core/hooks :as hooks)

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
   Returns a string (for text results) or a table/array (for structured content like images)."
  [name input]
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

(defn list-registered
  "Return a list of registered tool names."
  []
  (keys registry))
