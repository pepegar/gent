# test/test-sessions-explorer.janet — Tests for session metadata and explorer.

(import test/helper :as t)
(import core/conversation :as conv)
(import core/sessions-explorer :as explorer)
(import tui)

(print "\n── sessions-explorer ──")

# ── Helpers ─────────────────────────────────────────────────

(defn- setup-test-sessions
  "Create temp session directories with history and meta files for testing."
  []
  (def base (conv/project-sessions-dir))
  # Clean up any previous test sessions
  (when (os/stat base)
    (each entry (os/dir base)
      (when (string/has-prefix? "test-" entry)
        (def dir (string base "/" entry))
        (when (os/stat (string dir "/history")) (os/rm (string dir "/history")))
        (when (os/stat (string dir "/meta")) (os/rm (string dir "/meta")))
        (os/rm dir))))
  # Create test sessions
  (defn make-session [id parent fork-point msgs]
    (def dir (string base "/" id))
    (os/mkdir dir)
    (def history (string dir "/history"))
    (spit history "")
    (each m msgs
      (spit history (string (string/format "%j" m) "\n") :a))
    (spit (string dir "/meta")
      (string/format "%j" {:parent parent :fork-point fork-point :created-at 1741641935})))
  (make-session "test-root-001"  nil nil
    [{:role "user" :content "hello"} {:role "assistant" :content "hi"}])
  (make-session "test-child-001" "test-root-001" 2
    [{:role "user" :content "hello"} {:role "assistant" :content "hi"}
     {:role "user" :content "fork message"}])
  (make-session "test-root-002"  nil nil
    [])
  base)

(defn- cleanup-test-sessions []
  (def base (conv/project-sessions-dir))
  (when (os/stat base)
    (each entry (os/dir base)
      (when (string/has-prefix? "test-" entry)
        (def dir (string base "/" entry))
        (when (os/stat (string dir "/history")) (os/rm (string dir "/history")))
        (when (os/stat (string dir "/meta")) (os/rm (string dir "/meta")))
        (os/rm dir)))))

# ── Phase 1: Metadata tests ────────────────────────────────

(t/test "read-session-meta returns nil for missing meta" (fn []
                                                          (setup-test-sessions)
  # Remove meta file from one session
                                                          (def base (conv/project-sessions-dir))
                                                          (def meta-path (string base "/test-root-002/meta"))
                                                          (os/rm meta-path)
                                                          (def meta (conv/read-session-meta "test-root-002"))
                                                          (t/assert= meta nil)
                                                          (cleanup-test-sessions)))

(t/test "read-session-meta returns parsed data" (fn []
                                                 (setup-test-sessions)
                                                 (def meta (conv/read-session-meta "test-child-001"))
                                                 (t/assert-truthy (not (nil? meta)))
                                                 (t/assert= (get meta :parent) "test-root-001")
                                                 (t/assert= (get meta :fork-point) 2)
                                                 (cleanup-test-sessions)))

(t/test "count-session-messages counts correctly" (fn []
                                                   (setup-test-sessions)
                                                   (t/assert= (conv/count-session-messages "test-root-001") 2)
                                                   (t/assert= (conv/count-session-messages "test-child-001") 3)
                                                   (t/assert= (conv/count-session-messages "test-root-002") 0)
                                                   (cleanup-test-sessions)))

(t/test "build-session-tree groups children under parents" (fn []
                                                            (setup-test-sessions)
                                                            (def sessions (conv/list-sessions-with-meta))
  # Filter to our test sessions only
                                                            (def test-sessions (filter |(string/has-prefix? "test-" ($ :id)) sessions))
                                                            (def tree (conv/build-session-tree test-sessions))
  # Should have 2 root nodes (test-root-001 and test-root-002)
                                                            (t/assert= (length tree) 2)
  # Find root-001 and verify it has child-001
                                                            (var found-root nil)
                                                            (each node tree
                                                              (when (= (node :id) "test-root-001")
                                                                (set found-root node)))
                                                            (t/assert-truthy (not (nil? found-root)))
                                                            (t/assert= (length (found-root :children)) 1)
                                                            (t/assert= ((get (found-root :children) 0) :id) "test-child-001")
  # Find root-002 and verify it has no children
                                                            (var found-root2 nil)
                                                            (each node tree
                                                              (when (= (node :id) "test-root-002")
                                                                (set found-root2 node)))
                                                            (t/assert-truthy (not (nil? found-root2)))
                                                            (t/assert= (length (found-root2 :children)) 0)
                                                            (cleanup-test-sessions)))

# ── Phase 2: Explorer state machine ────────────────────────

(t/test "initially idle" (fn []
                          (explorer/reset-state)
                          (t/assert-falsy (explorer/active?))))

(t/test "open activates explorer" (fn []
                                   (setup-test-sessions)
                                   (explorer/reset-state)
                                   (explorer/open)
                                   (t/assert-truthy (explorer/active?))
                                   (explorer/close)
                                   (cleanup-test-sessions)))

(t/test "close deactivates" (fn []
                             (setup-test-sessions)
                             (explorer/reset-state)
                             (explorer/open)
                             (explorer/close)
                             (t/assert-falsy (explorer/active?))
                             (cleanup-test-sessions)))

(t/test "open returns result-box" (fn []
                                   (setup-test-sessions)
                                   (explorer/reset-state)
                                   (def rb (explorer/open))
                                   (t/assert-truthy (table? rb))
                                   (t/assert= (rb :action) nil)
                                   (t/assert= (rb :session-id) nil)
                                   (explorer/close)
                                   (cleanup-test-sessions)))

# ── Navigation ──────────────────────────────────────────────

(t/test "select-next and select-prev wrap" (fn []
                                            (setup-test-sessions)
                                            (explorer/reset-state)
                                            (explorer/open)
                                            (def entry1 (explorer/get-selected))
                                            (explorer/select-next)
                                            (def entry2 (explorer/get-selected))
                                            (t/assert-truthy (not= (get-in entry1 [:session :id]) (get-in entry2 [:session :id])))
                                            (explorer/select-prev)
                                            (def entry3 (explorer/get-selected))
                                            (t/assert= (get-in entry1 [:session :id]) (get-in entry3 [:session :id]))
                                            (explorer/close)
                                            (cleanup-test-sessions)))

# ── Key handling ────────────────────────────────────────────

(t/test "handle-key returns nil when idle" (fn []
                                            (explorer/reset-state)
                                            (t/assert= (explorer/handle-key {:key :up}) nil)))

(t/test "handle-key escape closes" (fn []
                                    (setup-test-sessions)
                                    (explorer/reset-state)
                                    (explorer/open)
                                    (explorer/handle-key {:key :escape})
                                    (t/assert-falsy (explorer/active?))
                                    (cleanup-test-sessions)))

(t/test "handle-key j/k navigates" (fn []
                                    (setup-test-sessions)
                                    (explorer/reset-state)
                                    (explorer/open)
                                    (def entry1 (explorer/get-selected))
                                    (explorer/handle-key {:key "j"})
                                    (def entry2 (explorer/get-selected))
                                    (t/assert-truthy (not= (get-in entry1 [:session :id]) (get-in entry2 [:session :id])))
                                    (explorer/handle-key {:key "k"})
                                    (def entry3 (explorer/get-selected))
                                    (t/assert= (get-in entry1 [:session :id]) (get-in entry3 [:session :id]))
                                    (explorer/close)
                                    (cleanup-test-sessions)))

# ── Render overlay ──────────────────────────────────────────

(t/test "render-overlay returns nil when idle" (fn []
                                                (explorer/reset-state)
                                                (def area (tui/rect 0 0 80 24))
                                                (t/assert= (explorer/render-overlay area) nil)))

(t/test "render-overlay returns cell structure" (fn []
                                                 (setup-test-sessions)
                                                 (explorer/reset-state)
                                                 (explorer/open)
                                                 (def area (tui/rect 0 0 100 30))
                                                 (def result (explorer/render-overlay area))
                                                 (t/assert-truthy (not (nil? result)))
                                                 (t/assert-truthy (> (length (result :cells)) 0))
                                                 (t/assert-truthy (> (result :width) 0))
                                                 (t/assert-truthy (> (result :height) 0))
                                                 (explorer/close)
                                                 (cleanup-test-sessions)))

(t/test "render-overlay is centered" (fn []
                                      (setup-test-sessions)
                                      (explorer/reset-state)
                                      (explorer/open)
                                      (def area (tui/rect 0 0 100 30))
                                      (def result (explorer/render-overlay area))
                                      (def expected-x (math/floor (/ (- 100 (result :width)) 2)))
                                      (def expected-y (math/floor (/ (- 30 (result :height)) 2)))
                                      (t/assert= (result :x) expected-x)
                                      (t/assert= (result :y) expected-y)
                                      (explorer/close)
                                      (cleanup-test-sessions)))

(t/test "render-overlay corners are rounded" (fn []
                                              (setup-test-sessions)
                                              (explorer/reset-state)
                                              (explorer/open)
                                              (def area (tui/rect 0 0 100 30))
                                              (def result (explorer/render-overlay area))
                                              (def cells (result :cells))
                                              (def tl (get cells 0))
                                              (t/assert= (tl :ch) "╭")
                                              (def last-cell (get cells (- (length cells) 1)))
                                              (t/assert= (last-cell :ch) "╯")
                                              (explorer/close)
                                              (cleanup-test-sessions)))

# ── Search ──────────────────────────────────────────────────

(t/test "search filters sessions" (fn []
                                   (setup-test-sessions)
                                   (explorer/reset-state)
                                   (explorer/open)
                                   (explorer/search-insert "c")
                                   (explorer/search-insert "h")
                                   (explorer/search-insert "i")
                                   (explorer/search-insert "l")
                                   (explorer/search-insert "d")
  # Query "child" should filter to just the child session
                                   (t/assert= (explorer/get-query) "child")
                                   (explorer/close)
                                   (cleanup-test-sessions)))

(t/test "search-clear resets filter" (fn []
                                      (setup-test-sessions)
                                      (explorer/reset-state)
                                      (explorer/open)
                                      (explorer/search-insert "x")
                                      (explorer/search-clear)
                                      (t/assert= (explorer/get-query) "")
                                      (explorer/close)
                                      (cleanup-test-sessions)))

# ── Expand/Collapse ────────────────────────────────────────

(t/test "tab expands session to show messages" (fn []
                                                 (setup-test-sessions)
                                                 (explorer/reset-state)
                                                 (explorer/open)
  # Navigate to test-root-001 which has 2 messages
                                                 (var found-idx nil)
                                                 (for i 0 20
                                                   (def entry (explorer/get-selected))
                                                   (when (and entry
                                                              (= :session (get entry :type))
                                                              (= "test-root-001" (get-in entry [:session :id])))
                                                     (set found-idx i)
                                                     (break))
                                                   (explorer/select-next))
                                                 (t/assert-truthy (not (nil? found-idx)))
  # Tab to expand
                                                 (explorer/toggle-expand)
  # Now the next entry should be a message row
                                                 (explorer/select-next)
                                                 (def entry (explorer/get-selected))
                                                 (t/assert= (get entry :type) :message)
                                                 (t/assert= (entry :session-id) "test-root-001")
                                                 (t/assert= (entry :msg-index) 1)
                                                 (explorer/close)
                                                 (cleanup-test-sessions)))

(t/test "tab collapses expanded session" (fn []
                                           (setup-test-sessions)
                                           (explorer/reset-state)
                                           (explorer/open)
  # Navigate to test-root-001
                                           (var found false)
                                           (for i 0 20
                                             (def entry (explorer/get-selected))
                                             (when (and entry
                                                        (= :session (get entry :type))
                                                        (= "test-root-001" (get-in entry [:session :id])))
                                               (set found true)
                                               (break))
                                             (explorer/select-next))
                                           (t/assert-truthy found)
  # Expand
                                           (explorer/toggle-expand)
                                           (explorer/select-next)
                                           (t/assert= (get (explorer/get-selected) :type) :message)
  # Go back to session and collapse
                                           (explorer/select-prev)
                                           (explorer/toggle-expand)
  # Next entry should now be a session, not a message
                                           (explorer/select-next)
                                           (def entry (explorer/get-selected))
                                           (t/assert= (get entry :type) :session)
                                           (explorer/close)
                                           (cleanup-test-sessions)))

(t/test "enter on message row triggers fork-at-message" (fn []
                                                          (setup-test-sessions)
                                                          (explorer/reset-state)
                                                          (explorer/open)
  # Navigate to test-root-001
                                                          (for i 0 20
                                                            (def entry (explorer/get-selected))
                                                            (when (and entry
                                                                       (= :session (get entry :type))
                                                                       (= "test-root-001" (get-in entry [:session :id])))
                                                              (break))
                                                            (explorer/select-next))
  # Expand and select first message
                                                          (explorer/toggle-expand)
                                                          (explorer/select-next)
                                                          (def entry (explorer/get-selected))
                                                          (t/assert= (get entry :type) :message)
                                                          (t/assert= (entry :msg-index) 1)
  # Enter on message should fork
                                                          (explorer/handle-key {:key :enter})
  # Explorer should be closed
                                                          (t/assert-falsy (explorer/active?))
  # Should have forked — new session has 1 message
                                                          (t/assert= (conv/length) 1)
                                                          (cleanup-test-sessions)))
