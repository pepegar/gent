# Hooks - Extending Behavior

Hooks let you extend gent's behavior at key points. All hooks are optional.

## Available Hooks

```janet
(import core/hooks :as hooks)

# Called before any tool executes
(hooks/add :before-tool-call
  (fn [name input]
    # name is tool name string, input is the tool arguments table
    (printf "About to run tool: %s" name)))

# Called after any tool executes
(hooks/add :after-tool-call
  (fn [name input result]
    # result is the tool's return value
    (printf "Tool %s returned: %s" name (string result))))

# Custom tool call rendering (return truthy to suppress default)
(hooks/add :render-tool-call
  (fn [name input]
    (when (= name "my-tool")
      (printf "Custom rendering for my-tool!")
      true)))  # Suppress default rendering

# Custom tool result rendering
(hooks/add :render-tool-result
  (fn [name result]
    (when (= name "my-tool")
      (printf "Custom result: %s" (string result))
      true)))

# Called before sending request to LLM
(hooks/add :before-send
  (fn [conversation]
    # Can modify the conversation array
    (printf "Sending %d messages to LLM" (length conversation))))

# Called after receiving LLM response
(hooks/add :after-response
  (fn [response]
    (printf "Got response with %d content blocks"
            (length (get response :content @[])))))

# Called on any error
(hooks/add :on-error
  (fn [err]
    (printf "Error occurred: %s" (string err))))

# Called when conversation is cleared
(hooks/add :conversation-clear
  (fn [] (printf "Conversation cleared")))

# Called after rolling back messages
(hooks/add :conversation-rollback
  (fn [n] (printf "Rolled back %d messages" n)))
```

## Example: Tool Logging

Log all tool calls to a file:

```janet
(import core/hooks :as hooks)

(hooks/add :before-tool-call
  (fn [name input]
    (spit "tool-log.txt"
          (string (os/date) " CALL " name " " (json/encode input) "\n")
          :a)))  # :a means append

(hooks/add :after-tool-call
  (fn [name input result]
    (spit "tool-log.txt"
          (string (os/date) " RESULT " name " " (json/encode result) "\n")
          :a)))
```

## Example: Tool Guards

Prevent certain operations:

```janet
(hooks/add :before-tool-call
  (fn [name input]
    # Don't allow editing files in vendor/
    (when (and (= name "edit_file")
               (string/has-prefix? "vendor/" (get input :path "")))
      (error "Refusing to edit vendor/ files"))))
```
