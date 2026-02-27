# Tests for core/input-history
(import core/input-history :as ih)
(import test/helper :as t)

(print "── core/input-history ──")

# ── Setup helper ─────────────────────────────────────────────

(defn- fresh []
  "Reset history state before each test."
  (ih/clear))

# ── Tests ────────────────────────────────────────────────────

(t/test "push adds entries" (fn []
                             (fresh)
                             (ih/push "hello")
                             (ih/push "world")
                             (t/assert= (ih/get-entries) @["hello" "world"])))

(t/test "push skips empty strings" (fn []
                                    (fresh)
                                    (ih/push "")
                                    (ih/push nil)
                                    (t/assert= (ih/get-entries) @[])))

(t/test "push skips consecutive duplicates" (fn []
                                             (fresh)
                                             (ih/push "hello")
                                             (ih/push "hello")
                                             (ih/push "world")
                                             (ih/push "hello")
                                             (t/assert= (ih/get-entries) @["hello" "world" "hello"])))

(t/test "prev returns entries newest-first" (fn []
                                             (fresh)
                                             (ih/push "first")
                                             (ih/push "second")
                                             (ih/push "third")
                                             (t/assert= (ih/prev "draft") "third")
                                             (t/assert= (ih/prev "draft") "second")
                                             (t/assert= (ih/prev "draft") "first")
  # At oldest — returns nil
                                             (t/assert= (ih/prev "draft") nil)))

(t/test "next returns entries and then draft" (fn []
                                               (fresh)
                                               (ih/push "first")
                                               (ih/push "second")
                                               (ih/push "third")
  # Go to oldest
                                               (ih/prev "my draft")
                                               (ih/prev "my draft")
                                               (ih/prev "my draft")
  # Now go forward
                                               (t/assert= (ih/next) "second")
                                               (t/assert= (ih/next) "third")
  # Past newest — returns saved draft
                                               (t/assert= (ih/next) "my draft")))

(t/test "next returns nil when not browsing" (fn []
                                              (fresh)
                                              (ih/push "hello")
                                              (t/assert= (ih/next) nil)))

(t/test "draft is saved on first prev call" (fn []
                                             (fresh)
                                             (ih/push "old")
                                             (ih/prev "current typing")
  # Go forward past end to get draft back
                                             (t/assert= (ih/next) "current typing")))

(t/test "reset cancels browsing" (fn []
                                  (fresh)
                                  (ih/push "first")
                                  (ih/push "second")
                                  (ih/prev "draft")
                                  (t/assert-truthy (ih/browsing?))
                                  (ih/reset)
                                  (t/assert-falsy (ih/browsing?))
  # After reset, prev starts from end again
                                  (t/assert= (ih/prev "new draft") "second")))

(t/test "browsing? reflects state" (fn []
                                    (fresh)
                                    (t/assert-falsy (ih/browsing?))
                                    (ih/push "hello")
                                    (ih/prev "draft")
                                    (t/assert-truthy (ih/browsing?))
                                    (ih/reset)
                                    (t/assert-falsy (ih/browsing?))))

(t/test "prev returns nil with empty history" (fn []
                                               (fresh)
                                               (t/assert= (ih/prev "draft") nil)))

(t/test "clear removes all entries" (fn []
                                     (fresh)
                                     (ih/push "a")
                                     (ih/push "b")
                                     (ih/prev "draft")
                                     (ih/clear)
                                     (t/assert= (ih/get-entries) @[])
                                     (t/assert-falsy (ih/browsing?))))

(t/test "prev then edit then prev restarts from end" (fn []
                                                      (fresh)
                                                      (ih/push "first")
                                                      (ih/push "second")
                                                      (ih/push "third")
  # Browse back two
                                                      (ih/prev "draft")   # => "third"
                                                      (ih/prev "draft")   # => "second"
  # User edits — reset
                                                      (ih/reset)
  # Browse again — starts from end
                                                      (t/assert= (ih/prev "new draft") "third")))

# ── init tests ───────────────────────────────────────────────

(defn- make-tmp-dir []
  "Create a temporary directory for test sessions."
  (def path (string "/tmp/.gent-test-" (math/floor (* (os/clock) 1000))))
  (os/mkdir path)
  path)

(defn- write-session [base-dir sid messages &opt mtime]
  "Write a mock session history file."
  (def session-dir (string base-dir "/" sid))
  (os/mkdir session-dir)
  (def history-path (string session-dir "/history"))
  (def buf @"")
  (each msg messages
    (buffer/push buf (string/format "%j" msg) "\n"))
  (spit history-path (string buf))
  # Set modification time if provided (touch with a delay to ensure ordering)
  (when mtime
    (os/sleep mtime)))

(defn- rm-rf [path]
  "Remove a directory recursively."
  (when (os/stat path)
    (when (= :directory ((os/stat path) :mode))
      (each f (os/dir path)
        (rm-rf (string path "/" f))))
    (os/rm path)))

(t/test "init loads user messages from sessions" (fn []
                                                  (def tmp (make-tmp-dir))
                                                  (defer (rm-rf tmp)
                                                    (write-session tmp "session1"
                                                      [{:role "user" :content "hello from session 1"}
                                                       {:role "assistant" :content "hi there"}
                                                       {:role "user" :content "second msg"}])
                                                    (write-session tmp "session2"
                                                      [{:role "user" :content "hello from session 2"}
                                                       {:role "assistant" :content "response"}]
                                                      0.01)
                                                    (ih/init tmp)
                                                    (def entries (ih/get-entries))
                                                    # Should have user string messages from both sessions
                                                    (t/assert-truthy (> (length entries) 0))
                                                    (t/assert-truthy (find |(= $ "hello from session 1") entries))
                                                    (t/assert-truthy (find |(= $ "second msg") entries))
                                                    (t/assert-truthy (find |(= $ "hello from session 2") entries)))))

(t/test "init skips tool result messages" (fn []
                                           (def tmp (make-tmp-dir))
                                           (defer (rm-rf tmp)
                                             (write-session tmp "session1"
                                               [{:role "user" :content "real input"}
                                                {:role "user" :content @[{:type "tool_result" :content "tool output" :tool_use_id "t1"}]}
                                                {:role "assistant" :content "ok"}])
                                             (ih/init tmp)
                                             (def entries (ih/get-entries))
                                             (t/assert= entries @["real input"]))))

(t/test "init skips context injections" (fn []
                                         (def tmp (make-tmp-dir))
                                         (defer (rm-rf tmp)
                                           (write-session tmp "session1"
                                             [{:role "user" :content "real input"}
                                              {:role "user" :content "[context] some injected context"}
                                              {:role "assistant" :content "ok"}])
                                           (ih/init tmp)
                                           (def entries (ih/get-entries))
                                           (t/assert= entries @["real input"]))))

(t/test "init skips empty strings and deduplicates" (fn []
                                                     (def tmp (make-tmp-dir))
                                                     (defer (rm-rf tmp)
                                                       (write-session tmp "session1"
                                                         [{:role "user" :content "hello"}
                                                          {:role "assistant" :content "hi"}
                                                          {:role "user" :content "hello"}])
                                                       (ih/init tmp)
                                                       (def entries (ih/get-entries))
                                                       # Consecutive "hello" should be deduped to one
                                                       (t/assert= entries @["hello"]))))

(t/test "init handles missing directory" (fn []
                                          (ih/init "/tmp/.gent-nonexistent-dir-12345")
                                          (t/assert= (ih/get-entries) @[])))

(t/test "init handles nil directory" (fn []
                                      (ih/init nil)
                                      (t/assert= (ih/get-entries) @[])))

(t/test "init handles empty sessions directory" (fn []
                                                 (def tmp (make-tmp-dir))
                                                 (defer (rm-rf tmp)
                                                   (ih/init tmp)
                                                   (t/assert= (ih/get-entries) @[]))))

(t/test "init handles corrupted history files" (fn []
                                                (def tmp (make-tmp-dir))
                                                (defer (rm-rf tmp)
                                                  (def session-dir (string tmp "/bad"))
                                                  (os/mkdir session-dir)
                                                  (spit (string session-dir "/history") "this is not valid janet {{{")
                                                  (write-session tmp "good"
                                                    [{:role "user" :content "valid input"}])
                                                  (ih/init tmp)
                                                  (def entries (ih/get-entries))
                                                  (t/assert= entries @["valid input"]))))

(t/test "push works after init" (fn []
                                 (def tmp (make-tmp-dir))
                                 (defer (rm-rf tmp)
                                   (write-session tmp "session1"
                                     [{:role "user" :content "old input"}])
                                   (ih/init tmp)
                                   (ih/push "new input")
                                   (def entries (ih/get-entries))
                                   (t/assert= entries @["old input" "new input"]))))

(t/test "prev browses across session history" (fn []
                                               (def tmp (make-tmp-dir))
                                               (defer (rm-rf tmp)
                                                 (write-session tmp "session1"
                                                   [{:role "user" :content "from session 1"}])
                                                 (write-session tmp "session2"
                                                   [{:role "user" :content "from session 2"}]
                                                   0.01)
                                                 (ih/init tmp)
                                                 (ih/push "current session")
                                                 # prev should walk back through all entries
                                                 (t/assert= (ih/prev "draft") "current session")
                                                 (t/assert= (ih/prev "draft") "from session 2")
                                                 (t/assert= (ih/prev "draft") "from session 1")
                                                 (t/assert= (ih/prev "draft") nil))))
