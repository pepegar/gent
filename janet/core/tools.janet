# Tool registry — the heart of extensibility.
# Tools are Janet tables with :name, :description, :schema, :function.
# The LLM can create new tools at runtime via eval-janet.

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
  "Execute a tool by name with the given input table. Returns a result string."
  [name input]
  (if-let [tool (get registry name)]
    (try
      (string ((tool :function) input))
      ([err] (string "Error executing " name ": " err)))
    (string "Unknown tool: " name)))

(defn list-registered
  "Return a list of registered tool names."
  []
  (keys registry))
