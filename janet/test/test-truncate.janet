# Test the new truncation system
(import test/helper :as t)
(import core/truncate :as trunc)

(t/test "format-size handles bytes correctly" (fn []
                                               (t/assert= "500B" (trunc/format-size 500))
                                               (t/assert= "1.5KB" (trunc/format-size 1536))
                                               (t/assert= "2.0MB" (trunc/format-size (* 2 1024 1024)))))

(t/test "truncate-head keeps first content within limits" (fn []
                                                           (def content "line1\nline2\nline3\nline4\nline5")
                                                           (def result (trunc/truncate-head content {:max-lines 3}))
  
                                                           (t/assert-truthy (result :truncated))
                                                           (t/assert= :lines (result :truncated-by))
                                                           (t/assert= "line1\nline2\nline3" (result :content))
                                                           (t/assert= 5 (result :total-lines))
                                                           (t/assert= 3 (result :output-lines))))

(t/test "truncate-tail keeps last content within limits" (fn []
                                                          (def content "line1\nline2\nline3\nline4\nline5")
                                                          (def result (trunc/truncate-tail content {:max-lines 3}))
  
                                                          (t/assert-truthy (result :truncated))
                                                          (t/assert= :lines (result :truncated-by))
                                                          (t/assert= "line3\nline4\nline5" (result :content))
                                                          (t/assert= 5 (result :total-lines))
                                                          (t/assert= 3 (result :output-lines))))

(t/test "truncate-head handles byte limit" (fn []
  # Test with multiple lines so we get some content back
                                            (def content (string (string/repeat "a" 30) "\n" (string/repeat "b" 30) "\n" (string/repeat "c" 30)))
                                            (def result (trunc/truncate-head content {:max-bytes 50}))
  
                                            (t/assert-truthy (result :truncated))
                                            (t/assert= :bytes (result :truncated-by))
                                            (t/assert= (+ 90 2) (result :total-bytes)) # 90 chars + 2 newlines
  # Should get just the first line (30 bytes, no newline since next line wouldn't fit)
                                            (t/assert= 30 (result :output-bytes))))

(t/test "no truncation when under limits" (fn []
                                           (def content "short\ncontent")
                                           (def result (trunc/truncate-head content))
  
                                           (t/assert-falsy (result :truncated))
                                           (t/assert= content (result :content))))

(t/test "make-truncation-notice creates helpful message" (fn []
                                                          (def truncation {:truncated true
                                                                           :truncated-by :lines
                                                                           :total-lines 1000
                                                                           :output-lines 500})
                                                          (def notice (trunc/make-truncation-notice truncation "/tmp/output.txt"))
  
                                                          (t/assert-truthy (string/find "501-1000 of 1000" notice))
                                                          (t/assert-truthy (string/find "/tmp/output.txt" notice))))
