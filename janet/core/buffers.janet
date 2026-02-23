# Buffers — named, mutable text containers.
# Like Emacs buffers: sit between disk and the agent.
# Every file edit flows through a buffer, making operations
# composable, hookable, and inspectable.
#
# Usage:
#   (import core/buffers :as buffers)
#   (def buf (buffers/open "src/main.rs"))
#   (buffers/replace buf "old" "new")
#   (buffers/save buf)

(import core/hooks :as hooks)

# ── Registry ───────────────────────────────────────────────────

(var- registry @{})
(var- current-name nil)

(defn- make-buffer [name content &opt path]
  @{:name name
    :content (if (buffer? content) content (buffer content))
    :path path
    :dirty false
    :point 0
    :meta @{}})

(defn- touch [buf]
  "Mark a buffer as current and dirty."
  (set current-name (buf :name))
  (put buf :dirty true)
  buf)

# ── Open / Create / Close ─────────────────────────────────────

(defn open
  "Open a file into a named buffer. Returns existing buffer if already open.
   Creates parent dirs and an empty buffer if the file doesn't exist yet."
  [path]
  (when-let [existing (get registry path)]
    (set current-name path)
    (break existing))
  (def content
    (if (os/stat path)
      (slurp path)
      ""))
  (def buf (make-buffer path content path))
  (put registry path buf)
  (set current-name path)
  (hooks/run :buffer-open path buf)
  buf)

(defn create
  "Create a scratch buffer (no disk path)."
  [name &opt content]
  (default content "")
  (when (get registry name)
    (error (string "buffer already exists: " name)))
  (def buf (make-buffer name content))
  (put registry name buf)
  (set current-name name)
  (hooks/run :buffer-open name buf)
  buf)

(defn get-buf
  "Get a buffer by name, or nil."
  [name]
  (get registry name))

(defn current
  "Get the most recently touched buffer, or nil."
  []
  (when current-name
    (get registry current-name)))

(defn list-bufs
  "List all open buffer names."
  []
  (keys registry))

(defn close
  "Close a buffer, removing it from the registry."
  [name]
  (when-let [buf (get registry name)]
    (hooks/run :buffer-close name buf)
    (put registry name nil)
    (when (= current-name name)
      (set current-name nil))
    true))

# ── Read ───────────────────────────────────────────────────────

(defn string-content
  "Get the buffer content as a string."
  [buf]
  (string (buf :content)))

(defn lines
  "Get the buffer content as an array of lines."
  [buf]
  (string/split "\n" (string (buf :content))))

(defn line
  "Get line n (0-indexed)."
  [buf n]
  (def ls (lines buf))
  (when (and (>= n 0) (< n (length ls)))
    (get ls n)))

# ── Point ─────────────────────────────────────────────────────

(defn get-point
  "Get the buffer's point (cursor position)."
  [buf]
  (buf :point))

(defn set-point
  "Set the buffer's point, clamped to [0, length]."
  [buf pos]
  (def len (length (buf :content)))
  (put buf :point (max 0 (min pos len))))

(defn point-at-end?
  "True if point is at the end of the buffer content."
  [buf]
  (= (buf :point) (length (buf :content))))

# ── Mutate ─────────────────────────────────────────────────────

(defn insert
  "Insert text at byte position."
  [buf pos text]
  (def c (buf :content))
  (when (or (< pos 0) (> pos (length c)))
    (error (string "insert position out of range: " pos)))
  (def n (length text))
  (def pt (buf :point))
  (def after (buffer/slice c pos))
  (buffer/popn c (- (length c) pos))
  (buffer/push c text)
  (buffer/push c after)
  (when (<= pos pt)
    (put buf :point (+ pt n)))
  (touch buf)
  (hooks/run :buffer-modified (buf :name) buf :insert)
  buf)

(defn delete
  "Delete bytes from start to end (exclusive)."
  [buf start end]
  (def c (buf :content))
  (when (or (< start 0) (> end (length c)) (> start end))
    (error (string "delete range out of bounds: " start "-" end)))
  (def pt (buf :point))
  (def before (buffer/slice c 0 start))
  (def after (buffer/slice c end))
  (buffer/clear c)
  (buffer/push c before)
  (buffer/push c after)
  (cond
    (<= end pt)   (put buf :point (- pt (- end start)))
    (<= start pt) (put buf :point start))
  (touch buf)
  (hooks/run :buffer-modified (buf :name) buf :delete)
  buf)

(defn replace
  "Replace the first occurrence of old with new. Errors if old is not found."
  [buf old new]
  (def c (buf :content))
  (def s (string c))
  (def idx (string/find old s))
  (unless idx
    (error "old string not found in buffer"))
  (def old-len (length old))
  (def new-len (length new))
  (def pt (buf :point))
  (def match-end (+ idx old-len))
  (def result (string/replace old new s))
  (buffer/clear c)
  (buffer/push c result)
  (cond
    (<= match-end pt) (put buf :point (+ pt (- new-len old-len)))
    (<= idx pt)       (put buf :point (+ idx new-len)))
  (touch buf)
  (hooks/run :buffer-modified (buf :name) buf :replace)
  buf)

(defn replace-all
  "Replace all occurrences of old with new. Errors if old is not found."
  [buf old new]
  (def c (buf :content))
  (def s (string c))
  (def result (string/replace-all old new s))
  (when (= s result)
    (error "old string not found in buffer"))
  (def old-len (length old))
  (def new-len (length new))
  (def pt (buf :point))
  (def matches (string/find-all old s))
  (var delta 0)
  (var new-point pt)
  (var resolved false)
  (each idx matches
    (def match-end (+ idx old-len))
    (cond
      (<= match-end pt)
      (+= delta (- new-len old-len))

      (<= idx pt)
      (do
        (set new-point (+ idx delta new-len))
        (set resolved true)
        (break))

      (do
        (set new-point (+ pt delta))
        (set resolved true)
        (break))))
  (unless resolved
    (set new-point (+ pt delta)))
  (buffer/clear c)
  (buffer/push c result)
  (put buf :point new-point)
  (touch buf)
  (hooks/run :buffer-modified (buf :name) buf :replace)
  buf)

# ── Disk ───────────────────────────────────────────────────────

(defn dirty?
  "Check if the buffer has unsaved changes."
  [buf]
  (buf :dirty))

(defn save
  "Write the buffer to disk. Only works for buffers with a :path."
  [buf]
  (unless (buf :path)
    (error (string "buffer '" (buf :name) "' has no path — use spit directly")))
  (hooks/run :buffer-save (buf :name) buf)
  # Create parent directories if needed
  (def parts (string/split "/" (buf :path)))
  (when (> (length parts) 1)
    (def dir (string/join (array/slice parts 0 -2) "/"))
    (os/mkdir dir))
  (spit (buf :path) (string (buf :content)))
  (put buf :dirty false)
  buf)

(defn reload
  "Re-read the buffer's file from disk, discarding in-memory changes."
  [buf]
  (unless (buf :path)
    (error (string "buffer '" (buf :name) "' has no path")))
  (def content (slurp (buf :path)))
  (buffer/clear (buf :content))
  (buffer/push (buf :content) content)
  (put buf :dirty false)
  (def len (length (buf :content)))
  (when (> (buf :point) len)
    (put buf :point len))
  buf)
