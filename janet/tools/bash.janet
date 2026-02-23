(import core/tools :as tools)

(defn- make-temp-paths []
  "Generate unique temp file paths for capturing bash output."
  (def id (string (os/clock) "-" (math/rng-int (math/rng) 999999999)))
  {:script (string "/tmp/.gent-" id ".sh")
   :stdout (string "/tmp/.gent-" id ".out")
   :stderr (string "/tmp/.gent-" id ".err")
   :done   (string "/tmp/.gent-" id ".done")})

(defn- cleanup-temp [paths]
  "Remove all temp files."
  (each key [:script :stdout :stderr :done]
    (def f (get paths key))
    (when (os/stat f)
      (os/rm f))))

(tools/register "bash"
  {:description ```Execute a bash command and return its output. Use this to run shell commands,
install packages, compile code, run tests, etc. The command runs in the current working directory.```
   :schema {:type "object"
            :properties {:command {:type "string"
                                   :description "The bash command to execute"}}
            :required ["command"]}
   :function (fn [input]
               (def cmd (get input :command))
               (def paths (make-temp-paths))

               # Write the user command to a temp script
               (spit (paths :script) cmd)

               # Spawn a bash wrapper that:
               #   1. Runs the script with stdout/stderr redirected to temp files
               #   2. Writes the exit code to a "done" marker file
               (def wrapper
                 (string "bash " (paths :script)
                         " > " (paths :stdout)
                         " 2> " (paths :stderr)
                         " ; echo $? > " (paths :done)))

               (var proc nil)
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
                   (when (os/stat (paths :done))
                     (def status-str (string/trim (slurp (paths :done))))
                     (def status (or (scan-number status-str) -1))
                     (def stdout (if (os/stat (paths :stdout)) (slurp (paths :stdout)) ""))
                     (def stderr (if (os/stat (paths :stderr)) (slurp (paths :stderr)) ""))
                     (when devnull (try (:close devnull) ([_] nil)))
                     (cleanup-temp paths)
                     [:done (string/format "exit code: %d\nstdout:\n%s\nstderr:\n%s"
                                           (math/round status)
                                           stdout
                                           stderr)]))

                 # cancel — kill the process tree and clean up
                 (fn []
                   (when proc
                     (try (os/proc-kill proc) ([_] nil)))
                   (when devnull (try (:close devnull) ([_] nil)))
                   (cleanup-temp paths))))})
