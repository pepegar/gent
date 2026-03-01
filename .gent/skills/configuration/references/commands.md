# Slash Commands

Add custom slash commands to gent.

## Basic Command

```janet
(import core/commands :as commands)
(import core/registers :as reg)

(commands/register "todo"
  {:description "Manage a todo list"
   :usage "/todo [item] — add item, or /todo to list"
   :function (fn [args]
               (var todos (or (reg/get :todos) @[]))
               (if (= "" (string/trim args))
                 # List todos
                 (if (empty? todos)
                   "No todos."
                   (string/join
                     (seq [i :range [0 (length todos)]]
                       (string (+ i 1) ". " (get todos i))) "\n"))
                 # Add todo
                 (do
                   (array/push todos args)
                   (reg/set :todos todos)
                   (string "Added: " args))))})

# Usage: /todo, /todo "Fix bug", /todo "Write docs"
```

## Command Definition

```janet
{:description "Brief description shown in /help"
 :usage "/command <args> — usage hint"
 :function (fn [args-string]
             # args-string is everything after the command name
             # Return a string to display, or nil for no output
             "Result")}
```

## Example: Note-taking Command

```janet
(import core/commands :as commands)
(import core/registers :as reg)

(commands/register "note"
  {:description "Take a quick note"
   :usage "/note <text>"
   :function (fn [args]
               (def notes (or (reg/get :notes) @[]))
               (def note (string (os/date) ": " args))
               (array/push notes note)
               (reg/set :notes notes)
               (string "Note saved: " note))})
```
