# Stage script: Rapid token streaming with zero delay
# Tests maximum throughput rendering - how fast can gent render incoming tokens?

(import core/stage :as stage)

(def content
  (string/join
    (seq [i :range [0 300]]
      (string "Line " i ": " (string/repeat "abcdefghij " 8) "\n"))
    ""))

# Zero delay = as fast as the event loop can drain
(stage/respond (stage/text-stream content :token-delay 0))
