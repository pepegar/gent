# Stage script: Multiple thinking blocks followed by text
# Tests thinking block rendering and expand/collapse

(import core/stage :as stage)

(def long-thinking
  (string/join
    (seq [i :range [0 50]]
      (string "Step " i ": Analyzing the problem from angle " i
        ". Consider the implications of approach " (% i 5)
        " combined with constraint " (% i 3) ". "
        "This requires careful consideration of edge cases "
        "and potential failure modes.\n"))
    ""))

(def long-response
  (string
    "# Analysis Complete\n\n"
    "After careful consideration, here are my findings:\n\n"
    "## Approach 1: Direct Optimization\n\n"
    "```janet\n"
    "(defn optimize-buffer [buf rect]\n"
    "  (def cells (buf :cells))\n"
    "  (def w (rect :width))\n"
    "  (for row 0 (rect :height)\n"
    "    (when (get-in buf [:dirty-rows row])\n"
    "      (for col 0 w\n"
    "        (def idx (+ (* row w) col))\n"
    "        (process-cell (get cells idx))))))\n"
    "```\n\n"
    "## Approach 2: Incremental Updates\n\n"
    "This approach minimizes the number of cells processed per frame by "
    "tracking **change regions** rather than individual cells.\n\n"
    "The key insight is that most frames only change a small fraction of "
    "the visible area, so a **region-based** dirty tracking system can "
    "skip entire rectangular areas.\n"))

# Queue 3 thinking-then-text responses for multi-turn interaction
(stage/sequence
  @[(stage/thinking-then-text long-thinking long-response)
    (stage/thinking-then-text
      (string "Second round of analysis...\n" long-thinking)
      (string "## Follow-up Analysis\n\n" long-response))
    (stage/thinking-then-text
      "Quick check on the final details..."
      "Done! All optimizations verified.")])
