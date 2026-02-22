# Abort flag — simple cancellation mechanism.
# When the user presses Escape during tool execution, the abort flag is set.
# Tools check (aborted?) before starting, and long-running operations
# (os/spawn processes, http/stream-start) can be stopped via their
# respective cancel/stop functions.

(var- flag false)

(defn abort!
  "Set the abort flag. Called when the user requests cancellation."
  []
  (set flag true))

(defn clear-abort!
  "Clear the abort flag. Called at the start of each tool execution batch."
  []
  (set flag false))

(defn aborted?
  "Check whether the abort flag is set."
  []
  flag)
