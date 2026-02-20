(import core/tools :as tools)

# The self-modification primitive.
# This is what makes gent a lisp machine — the LLM can extend itself at runtime.

(tools/register "eval_janet"
  {:description ```Evaluate Janet code in the running agent. Use this to:
- Define new tools at runtime
- Modify agent behavior
- Inspect agent state
- Run arbitrary Janet expressions
The code has full access to the agent runtime, including the tool registry.
Return value is converted to a string.```
   :schema {:type "object"
            :properties {:code {:type "string"
                                :description "Janet source code to evaluate"}}
            :required ["code"]}
   :function (fn [input]
               (def code (get input :code))
               (def result (eval-string code))
               (if (or (string? result) (number? result) (boolean? result) (nil? result))
                 (string result)
                 (string/format "%q" result)))})
