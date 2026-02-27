# Input History — shell-like history for the editor input line.
#
# Tracks submitted inputs and allows navigating them with Up/Down.
# Pure state module — no rendering, no keybinding awareness.
# On init, loads user inputs from all sessions in the project folder
# so history persists across sessions.
#
# Usage:
#   (import core/input-history :as ih)
#   (ih/init sessions-dir)           # load history from all sessions
#   (ih/push "some command")
#   (ih/prev "current draft")  # => "some command"
#   (ih/next)                  # => "current draft"

(var- entries @[])
(var- index nil)
(var- draft nil)
(var- max-entries 500)

(defn init
  "Load input history from all sessions in the given directory.
   Extracts :role \"user\" messages with string :content, skipping
   tool results and [context] injections. Sessions are sorted by
   history file modification time so newest entries come last."
  [sessions-dir]
  (array/clear entries)
  (set index nil)
  (set draft nil)
  (when (nil? sessions-dir) (break))
  (when (nil? (os/stat sessions-dir)) (break))
  (def session-ids (try (os/dir sessions-dir) ([_] @[])))
  (when (empty? session-ids) (break))

  # Collect (mtime, session-id) pairs and sort by mtime ascending
  (def sessions-with-mtime @[])
  (each sid session-ids
    (def history-path (string sessions-dir "/" sid "/history"))
    (def stat (os/stat history-path))
    (when stat
      (array/push sessions-with-mtime [(stat :modified) sid])))
  (sort-by first sessions-with-mtime)

  # Parse each session's history, extract user string messages
  (def all-inputs @[])
  (each [_ sid] sessions-with-mtime
    (def history-path (string sessions-dir "/" sid "/history"))
    (try
      (do
        (def content (slurp history-path))
        (def p (parser/new))
        (parser/consume p content)
        (while (parser/has-more p)
          (def msg (parser/produce p))
          (when (and (= (get msg :role) "user")
                     (string? (get msg :content))
                     (not (string/has-prefix? "[context]" (get msg :content))))
            (def text (get msg :content))
            (when (and (not= "" text)
                       (or (empty? all-inputs)
                           (not= text (last all-inputs))))
              (array/push all-inputs text)))))
      ([_] nil)))  # skip sessions with corrupted history

  # Take the last max-entries
  (def start (max 0 (- (length all-inputs) max-entries)))
  (for i start (length all-inputs)
    (array/push entries (get all-inputs i))))

(defn push
  "Add a submitted input to history. Skips empty strings and consecutive duplicates."
  [text]
  (when (or (nil? text) (= "" text))
    (break))
  (when (and (not (empty? entries)) (= text (last entries)))
    (break))
  (array/push entries text)
  (when (> (length entries) max-entries)
    (array/remove entries 0)))

(defn browsing?
  "Return true if currently navigating history."
  []
  (not (nil? index)))

(defn reset
  "Cancel history browsing. Call when the user edits text manually."
  []
  (set index nil)
  (set draft nil))

(defn prev
  "Move back in history. On first call, saves draft-text.
   Returns the history entry string, or nil if at the oldest entry."
  [draft-text]
  (when (empty? entries)
    (break nil))
  (if (nil? index)
    # First time pressing Up — save draft, start at end
    (do
      (set draft draft-text)
      (set index (- (length entries) 1))
      (get entries index))
    # Already browsing — go further back
    (if (> index 0)
      (do
        (-- index)
        (get entries index))
      nil)))

(defn next
  "Move forward in history. Returns the next entry, or the saved draft
   when moving past the newest entry. Returns nil if not browsing."
  []
  (when (nil? index)
    (break nil))
  (if (< index (- (length entries) 1))
    (do
      (++ index)
      (get entries index))
    # Past the end — restore draft
    (do
      (def saved draft)
      (set index nil)
      (set draft nil)
      saved)))

(defn get-entries
  "Return the history entries array (for inspection/testing)."
  []
  entries)

(defn clear
  "Clear all history entries and reset browsing state."
  []
  (array/clear entries)
  (reset))
