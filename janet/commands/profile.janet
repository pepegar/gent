(import core/commands :as commands)
(import core/profile :as profile)

(commands/register "profile"
  {:description "Profiling controls: stats, start, stop, dump, reset"
   :usage "/profile [stats|start|stop|dump [path]|reset]"
   :function (fn [args]
     (def subcmd (string/trim args))
     (cond
       (or (= subcmd "") (= subcmd "stats"))
       (if (profile/enabled?)
         (profile/format-stats)
         "Profiling is disabled. Use /profile start to enable.")

       (= subcmd "start")
       (do
         (profile/enable)
         "Profiling enabled.")

       (= subcmd "stop")
       (do
         (profile/disable)
         "Profiling disabled.")

       (string/has-prefix? "dump" subcmd)
       (do
         (def dump-args (string/trim (string/slice subcmd 4)))
         (def path
           (if (= dump-args "")
             (profile/export-trace)
             (profile/export-trace dump-args)))
         (string "Trace written to: " path "\nOpen in https://speedscope.app"))

       (= subcmd "reset")
       (do
         (profile/reset)
         "Profiling data cleared.")

       (string "Unknown subcommand: " subcmd
               "\nUsage: /profile [stats|start|stop|dump [path]|reset]")))})
