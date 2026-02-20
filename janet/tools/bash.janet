(import core/tools :as tools)

(tools/register "bash"
  {:description ```Execute a bash command and return its output. Use this to run shell commands,
install packages, compile code, run tests, etc. The command runs in the current working directory.```
   :schema {:type "object"
            :properties {:command {:type "string"
                                   :description "The bash command to execute"}}
            :required ["command"]}
   :function (fn [input]
               (def cmd (get input :command))
               (def result (process/exec "bash" ["-c" cmd]))
               (def status (get result :status))
               (def stdout (get result :stdout ""))
               (def stderr (get result :stderr ""))
               (string/format "exit code: %d\nstdout:\n%s\nstderr:\n%s"
                              (math/round status) stdout stderr))})
