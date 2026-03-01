# Creating Custom Tools

Define new tools at runtime.

## Simple Tool

```janet
(import core/tools :as tools)

# Simple tool
(tools/register "timestamp"
  {:description "Get the current timestamp"
   :schema {:type "object" :properties {} :required []}
   :function (fn [input] (string (os/date)))})
```

## Tool with Parameters

```janet
# Tool with parameters
(tools/register "greet"
  {:description "Greet someone"
   :schema {:type "object"
            :properties {:name {:type "string" :description "Name to greet"}}
            :required ["name"]}
   :function (fn [input]
               (string "Hello, " (get input :name "World") "!"))})
```

## Tool Using External Commands

```janet
# Tool that uses external commands
(tools/register "git-status"
  {:description "Show git repository status"
   :schema {:type "object" :properties {} :required []}
   :function (fn [input]
               (def result (process/exec "git" ["status" "--porcelain"]))
               (if (= 0 (result :status))
                 (result :stdout)
                 (string "Error: " (result :stderr))))})
```

## Async Tools

For long-running operations:

```janet
(import core/tools :as tools)

(tools/register "slow-task"
  {:description "A slow async operation"
   :schema {:type "object" :properties {} :required []}
   :function (tools/async-tool
               (fn [input callback]
                 # This runs in a separate thread
                 (os/sleep 5)  # Simulate work
                 (callback "Task completed!")))})
```

## Tool Schema

The `:schema` follows JSON Schema format:

```janet
{:type "object"
 :properties {:param1 {:type "string" :description "First parameter"}
              :param2 {:type "number" :description "Second parameter"}
              :optional {:type "boolean" :description "Optional flag"}}
 :required ["param1" "param2"]}
```
