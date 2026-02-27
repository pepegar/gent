# Tests for core/commands
(import core/commands :as commands)
(import test/helper :as t)

(print "── core/commands ──")

(t/test "register and dispatch" (fn []
                                 (commands/register "test-cmd"
                                   {:description "A test command"
                                    :usage "/test-cmd [arg]"
                                    :function (fn [args] (string "got: " args))})
                                 (def result (commands/dispatch "/test-cmd hello"))
                                 (t/assert-truthy (get result :handled))
                                 (t/assert= (get result :result) "got: hello")))

(t/test "dispatch non-command" (fn []
                                (def result (commands/dispatch "not a command"))
                                (t/assert-falsy (get result :handled))))

(t/test "dispatch unknown command" (fn []
                                    (def result (commands/dispatch "/nonexistent"))
                                    (t/assert-truthy (get result :handled))
                                    (t/assert-truthy (string/find "Unknown" (get result :result)))))

(t/test "dispatch no args" (fn []
                            (commands/register "noargs"
                              {:description "No args"
                               :function (fn [args] (string "args=[" args "]"))})
                            (def result (commands/dispatch "/noargs"))
                            (t/assert= (get result :result) "args=[]")))

(t/test "list-commands" (fn []
                         (def cmds (commands/list-commands))
                         (t/assert-truthy (> (length cmds) 0))
  # Each entry is [name description]
                         (t/assert-truthy (string? (get (first cmds) 0)))))

(t/test "command error is caught" (fn []
                                   (commands/register "errorcmd"
                                     {:description "Errors"
                                      :function (fn [args] (error "boom"))})
                                   (def result (commands/dispatch "/errorcmd"))
                                   (t/assert-truthy (get result :handled))
                                   (t/assert-truthy (string/find "boom" (get result :result)))))

(t/test "colon syntax dispatches to base command" (fn []
                                                   (commands/register "base"
                                                     {:description "Base command"
                                                      :function (fn [args] (string "arg=" args))})
                                                   (def result (commands/dispatch "/base:foo"))
                                                   (t/assert-truthy (get result :handled))
                                                   (t/assert= (get result :result) "arg=foo")))

(t/test "colon syntax with trailing args" (fn []
                                           (def result (commands/dispatch "/base:foo extra"))
                                           (t/assert-truthy (get result :handled))
                                           (t/assert= (get result :result) "arg=foo extra")))

(t/test "colon syntax unknown base is unknown" (fn []
                                                (def result (commands/dispatch "/unknown:foo"))
                                                (t/assert-truthy (get result :handled))
                                                (t/assert-truthy (string/find "Unknown" (get result :result)))))

(def pass (t/pass))
(def fail (t/fail))
