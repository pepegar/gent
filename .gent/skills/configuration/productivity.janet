# Simple Productivity Configuration 
# Working note-taking, bookmarks, and session tools

(print "Loading simple productivity tools...")

(import core/commands :as commands)
(import core/registers :as reg)
(import core/hooks :as hooks)

# Simple note-taking (no categories - just a list)
(commands/register "note"
  {:description "Take a quick note"
   :usage "/note <text>"
   :function (fn [args]
               (def notes (or (reg/get :notes) @[]))
               (def timestamp (string/format "%02d:%02d" 
                                           ((os/date) :hours)
                                           ((os/date) :minutes)))
               (def note-text (string timestamp " - " args))
               (array/push notes note-text)
               (reg/set :notes notes)
               (string "Note saved: " args))})

(commands/register "notes"
  {:description "List all notes"
   :usage "/notes"
   :function (fn [args]
               (def notes (or (reg/get :notes) @[]))
               (if (empty? notes)
                 "No notes found."
                 (string/join (map |(string "• " $) notes) "\n")))})

# Simple bookmarks
(commands/register "bookmark"
  {:description "Bookmark current directory"
   :usage "/bookmark <name>"
   :function (fn [args]
               (def name (string/trim args))
               (when (= "" name)
                 (break "Usage: /bookmark <name>"))
               (def bookmarks (or (reg/get :bookmarks) @{}))
               (def path (os/cwd))
               (put bookmarks name path)
               (reg/set :bookmarks bookmarks)
               (string "Bookmarked '" name "' -> " path))})

(commands/register "bookmarks"
  {:description "List bookmarks"
   :usage "/bookmarks"
   :function (fn [args]
               (def bookmarks (or (reg/get :bookmarks) @{}))
               (if (empty? bookmarks)
                 "No bookmarks found."
                 (string/join 
                   (seq [[name path] :pairs bookmarks]
                     (string "• " name " -> " path)) "\n")))})

(commands/register "goto"
  {:description "Go to bookmarked directory"
   :usage "/goto <bookmark>"
   :function (fn [args]
               (def name (string/trim args))
               (def bookmarks (or (reg/get :bookmarks) @{}))
               (def path (get bookmarks name))
               (if path
                 (do (os/cd path)
                     (string "Changed to: " path))
                 (string "Bookmark '" name "' not found")))})

# Session uptime
(def session-start-time (os/time))

(commands/register "uptime"
  {:description "Show session uptime"
   :usage "/uptime"
   :function (fn [args]
               (def elapsed (- (os/time) session-start-time))
               (def hours (math/floor (/ elapsed 3600)))
               (def minutes (math/floor (/ (% elapsed 3600) 60)))
               (def seconds (% elapsed 60))
               (if (> hours 0)
                 (string/format "Uptime: %dh %dm %ds" hours minutes seconds)
                 (string/format "Uptime: %dm %ds" minutes seconds)))})

# Session stats with hook
(hooks/add :after-response
  (fn [response]
    (def stats (or (reg/get :session-stats) @{:responses 0}))
    (put stats :responses (+ (stats :responses) 1))
    (reg/set :session-stats stats)))

(commands/register "stats"
  {:description "Show session statistics"
   :usage "/stats"
   :function (fn [args]
               (def stats (or (reg/get :session-stats) @{:responses 0}))
               (def notes (or (reg/get :notes) @[]))
               (def bookmarks (or (reg/get :bookmarks) @{}))
               (string/join @["Session Statistics:"
                              (string "  Responses: " (stats :responses))
                              (string "  Notes: " (length notes))
                              (string "  Bookmarks: " (length bookmarks))] "\n"))})

# Clear data commands  
(commands/register "clear-notes"
  {:description "Clear all notes"
   :usage "/clear-notes"
   :function (fn [args]
               (reg/set :notes @[])
               "All notes cleared.")})

(commands/register "clear-bookmarks"
  {:description "Clear all bookmarks"
   :usage "/clear-bookmarks" 
   :function (fn [args]
               (reg/set :bookmarks @{})
               "All bookmarks cleared.")})

(print "Simple productivity tools loaded!")
(print "Available: /note, /notes, /bookmark, /bookmarks, /goto, /uptime, /stats")
(print "Utilities: /clear-notes, /clear-bookmarks")