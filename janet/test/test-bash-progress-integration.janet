# test/test-bash-progress-integration.janet — Integration test for bash progress.
#
# Tests the full flow: stage sends a bash tool call, the tool emits partial
# output, progress lines appear in scrollback, then the tool completes and
# progress lines are replaced with the final result.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/stage :as stage)
(import core/scenario :as sc)
(import core/tools :as tools)
(import widgets/chat :as chat)
(import test/helper :as t)
(import test/stage-helpers :as sh)

(print "── bash progress integration ──")

(defn- has-progress? []
  (> (length (filter |(get $ :progress) (chat/get-scrollback))) 0))

(t/test "bash tool call with partial output shows progress then result" (fn []
                                                                         (sh/setup-stage)

                                                                         (var poll-count 0)
                                                                         (tools/register "bash"
                                                                           {:description "test bash"
                                                                            :schema {:type "object"
                                                                                     :properties {:command {:type "string"}}
                                                                                     :required ["command"]}
                                                                            :function (fn [input]
                                                                                       (tools/async-tool
                                                                                         (fn []
                                                                                           (++ poll-count)
                                                                                           (cond
                                                                                             (= poll-count 1) nil
                                                                                             (= poll-count 2) [:partial "Building...\nCompiling main.rs\nCompiling lib.rs\n"]
                                                                                             (= poll-count 3) [:partial "Building...\nCompiling main.rs\nCompiling lib.rs\nCompiling tools.rs\nLinking...\n"]
                                                                                             (= poll-count 4) [:done "Build complete!\n"]))
                                                                                         (fn [] nil)))})

                                                                         (stage/respond (stage/tool-call "bash" {:command "cargo build"} :id "bash_1"))
                                                                         (stage/respond (stage/text "Build succeeded!"))

                                                                         (sc/submit "build it")

  # Tick until progress lines appear (partial output received)
                                                                         (sc/tick-until has-progress?)

  # Should show first batch of output
                                                                         (t/assert-truthy (sc/find-in-scrollback "Compiling main.rs"))
                                                                         (t/assert-truthy (sc/find-in-scrollback "Compiling lib.rs"))

  # Next tick: second partial with more output
                                                                         (sc/tick)
                                                                         (t/assert-truthy (sc/find-in-scrollback "Compiling tools.rs"))
                                                                         (t/assert-truthy (sc/find-in-scrollback "Linking..."))

  # Next tick: tool completes
                                                                         (sc/tick)

  # Progress lines removed, final result shown
                                                                         (t/assert-falsy (has-progress?))
                                                                         (t/assert-truthy (sc/find-in-scrollback "Build complete!"))

  # Follow-up response streams and completes
                                                                         (sc/tick-until-idle)
                                                                         (sc/assert-mode :idle)
                                                                         (sc/assert-visible "Build succeeded!")))

(t/test "bash progress is removed on tool error" (fn []
                                                  (sh/setup-stage)

                                                  (var poll-count 0)
                                                  (tools/register "bash"
                                                    {:description "test bash"
                                                     :schema {:type "object"
                                                              :properties {:command {:type "string"}}
                                                              :required ["command"]}
                                                     :function (fn [input]
                                                                (tools/async-tool
                                                                  (fn []
                                                                    (++ poll-count)
                                                                    (cond
                                                                      (= poll-count 1) nil
                                                                      (= poll-count 2) [:partial "Starting build...\n"]
                                                                      (= poll-count 3) [:error "Command timed out"]))
                                                                  (fn [] nil)))})

                                                  (stage/respond (stage/tool-call "bash" {:command "slow build"} :id "bash_2"))
                                                  (stage/respond (stage/text "The build failed."))

                                                  (sc/submit "build")

  # Tick until progress appears
                                                  (sc/tick-until has-progress?)
                                                  (t/assert-truthy (sc/find-in-scrollback "Starting build..."))

  # Next tick: error
                                                  (sc/tick)

  # Progress removed, error shown
                                                  (t/assert-falsy (has-progress?))
                                                  (t/assert-truthy (sc/find-in-scrollback "Command timed out"))

                                                  (sc/tick-until-idle)
                                                  (sc/assert-mode :idle)))

(def pass (t/pass))
(def fail (t/fail))
