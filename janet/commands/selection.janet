# commands/selection.janet — Selection-related slash commands

(import core/commands :as commands)
(import core/selection :as selection)

# ── /copy command ──────────────────────────────────────────────

(commands/register "copy"
  {:description "Copy the current text selection to clipboard"
   :usage "/copy"
   :function (fn [args]
               (if (selection/active?)
                 (do
                   (def text (selection/copy-selection))
                   (selection/clear)
                   (if text
                     (string "Copied " (length text) " characters:\n" 
                            (string/slice text 0 (min 100 (length text)))
                            (if (> (length text) 100) "..." ""))
                     "Failed to copy selection"))
                 "No active selection"))})

# ── /clear-selection command ───────────────────────────────────

(commands/register "clear-selection"
  {:description "Clear the current text selection"
   :usage "/clear-selection"
   :function (fn [args]
               (if (selection/active?)
                 (do
                   (selection/clear)
                   "Selection cleared")
                 "No active selection"))})