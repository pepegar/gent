(import core/tools :as tools)
(import core/truncate :as trunc)

(defn- make-temp-paths []
  "Generate unique temp file paths for capturing bash output."
  (def id (string (os/clock) "-" (math/rng-int (math/rng) 999999999)))
  {:script (string "/tmp/.gent-" id ".sh")
   :stdout (string "/tmp/.gent-" id ".out")
   :stderr (string "/tmp/.gent-" id ".err")
   :done   (string "/tmp/.gent-" id ".done")
   :full   (string "/tmp/.gent-" id ".full")}) # For storing full output

(defn- cleanup-temp [paths &opt keep-full]
  "Remove temp files, optionally keeping the full output file."
  (each key [:script :stdout :stderr :done]
    (def f (get paths key))
    (when (os/stat f)
      (os/rm f)))
  # Only remove full output if not keeping it
  (when (and (not keep-full) (os/stat (paths :full)))
    (os/rm (paths :full))))

(defn- read-output-chunk [stdout-path stderr-path last-stdout-size last-stderr-size]
  "Read new output since last check, returning {content new-stdout-size new-stderr-size}."
  (var stdout-content "")
  (var stderr-content "")
  (var new-stdout-size last-stdout-size)
  (var new-stderr-size last-stderr-size)
  
  # Read new stdout content
  (when (os/stat stdout-path)
    (def full-stdout (slurp stdout-path))
    (set new-stdout-size (length full-stdout))
    (when (> new-stdout-size last-stdout-size)
      (set stdout-content (string/slice full-stdout last-stdout-size))))
  
  # Read new stderr content  
  (when (os/stat stderr-path)
    (def full-stderr (slurp stderr-path))
    (set new-stderr-size (length full-stderr))
    (when (> new-stderr-size last-stderr-size)
      (set stderr-content (string/slice full-stderr last-stderr-size))))
  
  {:content (string stdout-content stderr-content)
   :stdout-size new-stdout-size
   :stderr-size new-stderr-size})

(defn- format-output [stdout stderr status truncation full-path]
  "Format the final tool output with truncation handling."
  (def combined (string stdout stderr))
  
  # Apply tail truncation (we want to see the end of bash output)
  (def trunc-result (trunc/truncate-tail combined))
  
  (var result-text "")
  
  (if (trunc-result :truncated)
    (do
      # Save full output to persistent temp file for LLM access
      (spit full-path combined)
      (def notice (trunc/make-truncation-notice trunc-result full-path))
      (set result-text (string result-text (trunc-result :content)))
      (set result-text (string result-text notice)))
    # Not truncated - show everything normally
    (do
      (set result-text (string result-text combined))))

  (if (not= status 0)
    (set result-text (string result-text (string/format "\n\nCommand exited with code %d" status))))
  
  result-text)

(tools/register "bash"
  {:description (string/format ```Execute a bash command and return its output. Use this to run shell commands,
install packages, compile code, run tests, etc. The command runs in the current working directory.
Output is truncated to last %d lines or %s (whichever is hit first). If truncated, full output is saved to a temp file.```
                               trunc/DEFAULT_MAX_LINES 
                               (trunc/format-size trunc/DEFAULT_MAX_BYTES))
   :schema {:type "object"
            :properties {:command {:type "string"
                                   :description "The bash command to execute"}
                         :timeout {:type "number"
                                   :description "Optional timeout in seconds"}}
            :required ["command"]}
   :function (fn [input]
               (def cmd (get input :command))
               (def timeout (get input :timeout))
               (def paths (make-temp-paths))

               # Write the user command to a temp script
               (spit (paths :script) cmd)

               # Create wrapper with timeout support
               (def wrapper
                 (if timeout
                   (string "timeout " timeout "s bash " (paths :script)
                           " > " (paths :stdout)
                           " 2> " (paths :stderr)
                           " ; echo $? > " (paths :done))
                   (string "bash " (paths :script)
                           " > " (paths :stdout)
                           " 2> " (paths :stderr)
                           " ; echo $? > " (paths :done))))

               (var proc nil)
               # Track start time for timeout handling
               (def start-time (os/clock))
               
               # Streaming state
               (var last-stdout-size 0)
               (var last-stderr-size 0)
               (def rolling-buffer @"")  # Keep recent output for streaming updates
               (def max-buffer-size (* 2 trunc/DEFAULT_MAX_BYTES))  # 2x the limit for rolling buffer
               
               # Open /dev/null for the child's stdin so it can't steal
               # terminal input from the TUI event loop.
               (def devnull (os/open "/dev/null" :r))
               (try
                 (set proc (os/spawn ["bash" "-c" wrapper] :p {:in devnull}))
                 ([err]
                   (when devnull (:close devnull))
                   (cleanup-temp paths)
                   (break (string "Error: failed to start process: " err))))

               # Return async tool handle — polled by the agent loop every ~16ms
               (tools/async-tool
                 # poll — non-blocking check for the done marker
                 (fn []
                   # Check for timeout
                   (when (and timeout (> (- (os/clock) start-time) timeout))
                     (when proc (try (os/proc-kill proc) ([_] nil)))
                     (when devnull (try (:close devnull) ([_] nil)))
                     (cleanup-temp paths)
                     (break [:error (string "Command timed out after " timeout " seconds")]))
                   
                   # Read new output for streaming (even if not done yet)
                   (def chunk-data (read-output-chunk (paths :stdout) (paths :stderr) 
                                                     last-stdout-size last-stderr-size))
                   (set last-stdout-size (chunk-data :stdout-size))
                   (set last-stderr-size (chunk-data :stderr-size))
                   
                   # Add new content to rolling buffer
                   (when (> (length (chunk-data :content)) 0)
                     (buffer/push rolling-buffer (chunk-data :content))
                     # Trim rolling buffer if too large (keep recent content)
                     (when (> (length rolling-buffer) max-buffer-size)
                       (def excess (- (length rolling-buffer) max-buffer-size))
                       (buffer/blit rolling-buffer rolling-buffer excess)
                       (buffer/popn rolling-buffer excess)))
                   
                   # Check if done
                   (if (os/stat (paths :done))
                     (do
                       # Process completed
                       (def status-str (string/trim (slurp (paths :done))))
                       (def status (or (scan-number status-str) -1))
                       (def stdout (if (os/stat (paths :stdout)) (slurp (paths :stdout)) ""))
                       (def stderr (if (os/stat (paths :stderr)) (slurp (paths :stderr)) ""))
                       
                       (when devnull (try (:close devnull) ([_] nil)))
                       
                       # Format output with truncation
                       (def formatted (format-output stdout stderr status nil (paths :full)))
                       
                       # Keep full output file if we created it, cleanup others
                       (def keep-full (os/stat (paths :full)))
                       (cleanup-temp paths keep-full)
                       
                       (if (= status 0)
                         [:done formatted]
                         [:error formatted]))
                     
                     # Still running - provide streaming update if we have content
                     (when (> (length rolling-buffer) 0)
                       (def buffer-content (string rolling-buffer))
                       (def trunc-result (trunc/truncate-tail buffer-content))
                       [:partial (trunc-result :content)])))

                 # cancel — kill the process tree and clean up
                 (fn []
                   (when proc
                     (try (os/proc-kill proc) ([_] nil)))
                   (when devnull (try (:close devnull) ([_] nil)))
                   (cleanup-temp paths))))})
