# test/test-spinner.janet — Tests for spinner animation during thinking.

(import test/fake-http :as fake)
(fake/install (curenv))

(import core/stage :as stage)
(import widgets/chat :as chat)
(import core/widget :as widget)
(import core/conversation :as conv)
(import core/scenario :as sc)
(import test/helper :as t)
(import test/stage-helpers :as sh)

(print "── spinner animation ──")

(t/test "spinner frame advances during thinking" (fn []
                                                  (def w (sh/setup-stage))
  # Use enough thinking chars that drain-stream (budget 32) can't consume
  # all SSE lines in a single tick. ~54 thinking chars → ~57 SSE lines.
                                                  (def thinking-text "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQR")
                                                  (stage/respond (stage/thinking-then-text thinking-text "done"))
                                                  (sc/submit "test")
  # First tick: processes first batch of thinking deltas, spinner becomes active
                                                  (sc/tick)
                                                  (def ss (chat/get-spinner-state))
                                                  (t/assert-truthy (ss :active))
                                                  (def frame1 (ss :frame))
  # Force the spinner interval to have elapsed so spinner-tick will advance
                                                  (put ss :last-tick (- (os/clock) 1))
  # Second tick: processes remaining thinking deltas + spinner-tick
                                                  (sc/tick)
                                                  (def frame2 (ss :frame))
  # The frame should have advanced (not been held at 0 by thinking-delta)
                                                  (t/assert-truthy (not= frame1 frame2))))

(t/test "thinking deltas update spinner message without resetting frame" (fn []
                                                                          (def w (sh/setup-stage))
                                                                          (def thinking-text "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQR")
                                                                          (stage/respond (stage/thinking-then-text thinking-text "done"))
                                                                          (sc/submit "test")
                                                                          (sc/tick)
                                                                          (def ss (chat/get-spinner-state))
                                                                          (t/assert-truthy (ss :active))
  # Manually set frame to 5 to verify thinking-delta doesn't reset it
                                                                          (put ss :frame 5)
                                                                          (put ss :last-tick (- (os/clock) 1))
                                                                          (sc/tick)
  # Frame should have advanced from 5, not been reset to 0
                                                                          (t/assert-truthy (not= 0 (ss :frame)))
  # Message should contain the thinking char count
                                                                          (t/assert-truthy (string/find "thinking" (ss :message)))))

(def pass (t/pass))
(def fail (t/fail))