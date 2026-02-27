# Output truncation utilities for tools
# Prevents command outputs from overwhelming LLM context

(def DEFAULT_MAX_LINES 2000)
(def DEFAULT_MAX_BYTES (* 50 1024)) # 50KB

(defn format-size
  "Format bytes as human-readable size."
  [bytes]
  (cond
    (< bytes 1024) (string bytes "B")
    (< bytes (* 1024 1024)) (string (string/format "%.1f" (/ bytes 1024.0)) "KB")
    (string (string/format "%.1f" (/ bytes 1024.0 1024.0)) "MB")))

(defn- byte-length
  "Get the byte length of a string (UTF-8)."
  [s]
  (length (buffer s)))

(defn truncate-head
  "Truncate content from the head (keep first N lines/bytes).
   Suitable for file reads where you want to see the beginning.
   
   Returns a table with:
   - :content - the truncated content
   - :truncated - true if truncation occurred
   - :truncated-by - :lines, :bytes, or nil
   - :total-lines - original line count
   - :total-bytes - original byte count
   - :output-lines - lines in truncated output
   - :output-bytes - bytes in truncated output"
  [content &opt options]
  (default options {})
  (def max-lines (get options :max-lines DEFAULT_MAX_LINES))
  (def max-bytes (get options :max-bytes DEFAULT_MAX_BYTES))
  
  (def total-bytes (byte-length content))
  (def lines (string/split "\n" content))
  (def total-lines (length lines))
  
  # Check if no truncation needed
  (when (and (<= total-lines max-lines) (<= total-bytes max-bytes))
    (break {:content content
            :truncated false
            :truncated-by nil
            :total-lines total-lines
            :total-bytes total-bytes
            :output-lines total-lines
            :output-bytes total-bytes}))
  
  # Check if first line alone exceeds byte limit
  (def first-line-bytes (byte-length (get lines 0)))
  (when (> first-line-bytes max-bytes)
    (break {:content ""
            :truncated true
            :truncated-by :bytes
            :total-lines total-lines
            :total-bytes total-bytes
            :output-lines 0
            :output-bytes 0}))
  
  # Collect complete lines that fit
  (def output-lines @[])
  (var output-bytes-count 0)
  (var truncated-by :lines)
  
  (loop [i :range [0 (min (length lines) max-lines)]]
    (def line (get lines i))
    (def line-bytes (+ (byte-length line) (if (> i 0) 1 0))) # +1 for newline
    
    (when (> (+ output-bytes-count line-bytes) max-bytes)
      (set truncated-by :bytes)
      (break))
    
    (array/push output-lines line)
    (+= output-bytes-count line-bytes))
  
  # If we exited due to line limit
  (when (and (>= (length output-lines) max-lines) (<= output-bytes-count max-bytes))
    (set truncated-by :lines))
  
  (def output-content (string/join output-lines "\n"))
  (def final-output-bytes (byte-length output-content))
  
  {:content output-content
   :truncated true
   :truncated-by truncated-by
   :total-lines total-lines
   :total-bytes total-bytes
   :output-lines (length output-lines)
   :output-bytes final-output-bytes})

(defn truncate-tail
  "Truncate content from the tail (keep last N lines/bytes).
   Suitable for bash output where you want to see the end (errors, final results).
   
   Returns same format as truncate-head."
  [content &opt options]
  (default options {})
  (def max-lines (get options :max-lines DEFAULT_MAX_LINES))
  (def max-bytes (get options :max-bytes DEFAULT_MAX_BYTES))
  
  (def total-bytes (byte-length content))
  (def lines (string/split "\n" content))
  (def total-lines (length lines))
  
  # Check if no truncation needed
  (when (and (<= total-lines max-lines) (<= total-bytes max-bytes))
    (break {:content content
            :truncated false
            :truncated-by nil
            :total-lines total-lines
            :total-bytes total-bytes
            :output-lines total-lines
            :output-bytes total-bytes}))
  
  # Work backwards from the end
  (def output-lines @[])
  (var output-bytes-count 0)
  (var truncated-by :lines)
  
  (loop [i :down [(- (length lines) 1) 0]]
    (when (>= (length output-lines) max-lines) (break))
    
    (def line (get lines i))
    (def line-bytes (+ (byte-length line) (if (> (length output-lines) 0) 1 0))) # +1 for newline
    
    (when (> (+ output-bytes-count line-bytes) max-bytes)
      (set truncated-by :bytes)
      # Edge case: if we haven't added ANY lines yet and this line exceeds maxBytes,
      # take the end of the line (partial)
      (when (= (length output-lines) 0)
        (def truncated-line (string/slice line (max 0 (- (length line) max-bytes))))
        (array/insert output-lines 0 truncated-line)
        (set output-bytes-count (byte-length truncated-line)))
      (break))
    
    (array/insert output-lines 0 line)
    (+= output-bytes-count line-bytes))
  
  # If we exited due to line limit
  (when (and (>= (length output-lines) max-lines) (<= output-bytes-count max-bytes))
    (set truncated-by :lines))
  
  (def output-content (string/join output-lines "\n"))
  (def final-output-bytes (byte-length output-content))
  
  {:content output-content
   :truncated true
   :truncated-by truncated-by
   :total-lines total-lines
   :total-bytes total-bytes
   :output-lines (length output-lines)
   :output-bytes final-output-bytes})

(defn make-truncation-notice
  "Create a helpful truncation notice for the LLM."
  [truncation temp-file]
  (when (not (truncation :truncated)) (break ""))
  
  (def start-line (+ (- (truncation :total-lines) (truncation :output-lines)) 1))
  (def end-line (truncation :total-lines))
  
  (def notice
    (cond
      (= (truncation :truncated-by) :lines)
      (string/format "\n\n[Showing lines %d-%d of %d. Full output: %s]"
                     start-line end-line (truncation :total-lines) temp-file)
      
      (string/format "\n\n[Showing lines %d-%d of %d (%s limit). Full output: %s]"
                     start-line end-line (truncation :total-lines)
                     (format-size DEFAULT_MAX_BYTES) temp-file)))
  
  notice)