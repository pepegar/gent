# Conversation Primitives — session management and message persistence.
# The conversation is an append-only log of Janet s-expressions,
# persisted to ~/.gent/sessions/<urlencode(cwd)>/<random-8-hex>/history.
#
# Every message is appended as it happens — crash-safe, inspectable,
# and composable (fork = copy the file).
#
# Usage:
#   (import core/conversation :as conv)
#   (conv/init)                          # create session, set up dirs
#   (conv/push {:role "user" :content "hello"})
#   (conv/get-messages)                  # => @[{:role "user" :content "hello"}]
#   (conv/list-sessions)                 # => @["a3f8b2c1" ...]
#   (conv/resume "a3f8b2c1")            # load a previous session

(import core/hooks :as hooks)

# Capture builtins before we shadow them
(def- len length)

# Shared RNG instance
(def- rng (math/rng))

# ── State ──────────────────────────────────────────────────────

(var- messages @[])
(var- session-id nil)
(var- session-dir nil)
(var- history-path nil)
(var- parent-session-id nil)   # for fork/unfork

# ── Helpers ────────────────────────────────────────────────────

(defn- url-encode
  "URL-encode a path string (encode non-alphanumeric chars as %XX)."
  [s]
  (def buf @"")
  (each byte s
    (if (or (<= (chr "a") byte (chr "z"))
            (<= (chr "A") byte (chr "Z"))
            (<= (chr "0") byte (chr "9"))
            (= byte (chr "-"))
            (= byte (chr "_"))
            (= byte (chr ".")))
      (buffer/push-byte buf byte)
      (buffer/push buf (string/format "%%%02X" byte))))
  (string buf))

(defn- sessions-base-dir
  "Return the base sessions directory.
   Checks in order: :gent/sessions-dir dyn var, GENT_SESSIONS_DIR env var, ~/.gent/sessions"
  []
  # Check for override from CLI flag or environment variable
  (if-let [override (or (dyn :gent/sessions-dir) (os/getenv "GENT_SESSIONS_DIR"))]
    override
    (do
      (def home (os/getenv "HOME"))
      (string home "/.gent/sessions"))))

(defn project-sessions-dir
  "Return the sessions directory for the current working directory."
  []
  (string (sessions-base-dir) "/" (url-encode (os/cwd))))

(defn- ensure-dir
  "Recursively create a directory path."
  [path]
  (def parts (string/split "/" path))
  (var current "")
  (each part parts
    (when (not= part "")
      (set current (string current "/" part))
      (when (not (os/stat current))
        (os/mkdir current)))))

(defn- timestamp-session-id
  "Generate a timestamp-based session ID: YYYYMMDD-HHMMSS-nnnn
   Handles same-second collisions with a counter file."
  []
  (def now (os/date))
  (def timestamp-base (string/format "%04d%02d%02d-%02d%02d%02d"
                                    (get now :year)
                                    (+ 1 (get now :month))  # month is 0-based
                                    (get now :month-day)
                                    (get now :hours)
                                    (get now :minutes)
                                    (get now :seconds)))
  
  # Handle collision detection with counter file
  (def sessions-dir (project-sessions-dir))
  (ensure-dir sessions-dir)
  (def counter-file (string sessions-dir "/." timestamp-base "-counter"))
  
  (def counter (if (os/stat counter-file)
                 (scan-number (string/trim (slurp counter-file)))
                 0))
  (def next-counter (+ counter 1))
  (spit counter-file (string next-counter))
  
  (string timestamp-base "-" (string/format "%04d" next-counter)))

(defn- random-hex
  "Generate n random hex characters."
  [n]
  (def buf @"")
  (for _ 0 n
    (buffer/push buf (string/format "%x" (math/rng-int rng 16))))
  (string buf))

(defn- append-to-log
  "Append a message to the session history file."
  [msg]
  (when history-path
    (spit history-path (string (string/format "%j" msg) "\n") :a)))

(defn load-history
  "Load messages from a history file using Janet's parser."
  [path]
  (def result @[])
  (def content (slurp path))
  (def p (parser/new))
  (parser/consume p content)
  (while (parser/has-more p)
    (array/push result (parser/produce p)))
  result)

# ── Initialization ─────────────────────────────────────────────

(defn init
  "Create a new session. Sets up the session directory and history file.
   Called once at startup."
  []
  (def sid (timestamp-session-id))
  (set session-id sid)
  (set session-dir (string (project-sessions-dir) "/" sid))
  (ensure-dir session-dir)
  (set history-path (string session-dir "/history"))
  # Create empty history file
  (spit history-path "")
  (set messages @[])
  (set parent-session-id nil)
  sid)

# ── Core Access ────────────────────────────────────────────────

(defn get-messages
  "Return the message array (mutable reference)."
  []
  messages)

(defn push
  "Append a message to the conversation and persist it."
  [msg]
  (array/push messages msg)
  (append-to-log msg)
  (hooks/run :after-message msg)
  msg)

(defn length
  "Return the number of messages in the conversation."
  []
  (len messages))

(defn clear
  "Reset the conversation. Starts fresh in the same session (rewrites history)."
  []
  (array/clear messages)
  (when history-path
    (spit history-path ""))
  (hooks/run :conversation-clear)
  nil)

# ── Session Management ─────────────────────────────────────────

(defn get-session-id
  "Return the current session ID."
  []
  session-id)

(defn get-session-path
  "Return the path to the current history file."
  []
  history-path)

(defn list-sessions
  "List all session IDs for the current working directory."
  []
  (def dir (project-sessions-dir))
  (if (os/stat dir)
    (sort (os/dir dir))
    @[]))

(defn resume
  "Load a previous session's history and switch to it."
  [sid]
  (def dir (string (project-sessions-dir) "/" sid))
  (def path (string dir "/history"))
  (unless (os/stat path)
    (error (string "session not found: " sid)))
  (set session-id sid)
  (set session-dir dir)
  (set history-path path)
  (set messages (load-history path))
  (set parent-session-id nil)
  (hooks/run :session-resume sid)
  messages)

# ── Rollback ───────────────────────────────────────────────────

(defn rollback
  "Remove the last n messages. Rewrites the session file."
  [n]
  (def count (min n (len messages)))
  (for _ 0 count
    (array/pop messages))
  # Rewrite the history file from the remaining messages
  (when history-path
    (spit history-path "")
    (each msg messages
      (spit history-path (string (string/format "%j" msg) "\n") :a)))
  (hooks/run :conversation-rollback n)
  messages)

# ── Fork / Unfork ──────────────────────────────────────────────

(defn fork
  "Copy the current history to a new session and switch to it.
   Returns the new session ID."
  []
  (def old-sid session-id)
  (def old-history history-path)
  (def new-sid (timestamp-session-id))
  (def new-dir (string (project-sessions-dir) "/" new-sid))
  (ensure-dir new-dir)
  (def new-path (string new-dir "/history"))
  # Copy the history file
  (when old-history
    (if (os/stat old-history)
      (spit new-path (slurp old-history))
      (spit new-path "")))
  (set parent-session-id old-sid)
  (set session-id new-sid)
  (set session-dir new-dir)
  (set history-path new-path)
  (hooks/run :session-fork old-sid new-sid)
  new-sid)

(defn unfork
  "Return to the parent session (before the last fork).
   Returns the parent session ID, or nil if there's no parent."
  []
  (unless parent-session-id
    (break nil))
  (resume parent-session-id)
  (def pid parent-session-id)
  (set parent-session-id nil)
  pid)

# ── Context Window Helpers ─────────────────────────────────────

(defn estimate-tokens
  "Rough token estimate for the current conversation (chars / 4)."
  []
  (var total 0)
  (each msg messages
    (def content (get msg :content ""))
    (if (string? content)
      (set total (+ total (len content)))
      # Array content (tool use blocks etc.)
      (each block content
        (when (string? (get block :text))
          (set total (+ total (len (get block :text)))))
        (when (string? (get block :content))
          (set total (+ total (len (get block :content))))))))
  (math/ceil (/ total 4)))

(defn inject-context
  "Add a context message mid-conversation (as a user message with a [context] prefix)."
  [text]
  (push {:role "user" :content (string "[context] " text)}))
