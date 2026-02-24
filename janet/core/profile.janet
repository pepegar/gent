# core/profile.janet — Lightweight profiling system.
#
# Records timing spans, accumulates per-operation stats, and exports
# Chrome Trace Event JSON for flame graph visualization in speedscope.app.
#
# Near-zero overhead when disabled: every function early-returns on a
# `(not enabled)` check. with-span calls (f) directly when profiling
# is off, adding only one boolean check.
#
# Activation:
#   GENT_PROFILE=1 cargo run   — auto-enables on boot
#   /profile start             — toggle during session
#   (profile/enable)           — from init.janet or eval_janet

(import core/hooks :as hooks)

(var- enabled false)
(var- stats @{})
(var- trace-events @[])
(var- span-stack @[])
(var- next-span-id 0)
(def- max-trace-events 10000)
(var- start-time nil)

(var- before-tool-hook nil)
(var- after-tool-hook nil)
(var- tool-span-ids @{})

# ── Public API ────────────────────────────────────────────────

(defn enabled? [] enabled)

(defn begin
  "Start a profiling span. Returns span-id or nil if disabled."
  [name cat]
  (when (not enabled) (break nil))
  (def id next-span-id)
  (++ next-span-id)
  (def ts (os/clock))
  (array/push span-stack @{:id id :name name :cat cat :ts ts :args nil})
  id)

(defn end
  "End a profiling span by id. Computes duration, updates stats, appends trace event."
  [span-id]
  (when (nil? span-id) (break))
  (def end-ts (os/clock))
  # Find and remove span from stack (iterate backwards)
  (var span nil)
  (var idx nil)
  (var i (- (length span-stack) 1))
  (while (>= i 0)
    (when (= (get-in span-stack [i :id]) span-id)
      (set span (get span-stack i))
      (set idx i)
      (break))
    (-- i))
  (when (nil? span) (break))
  (array/remove span-stack idx)
  (def dur-us (* (- end-ts (span :ts)) 1000000))
  (def name (span :name))
  # Update stats
  (unless (get stats name)
    (put stats name @{:count 0 :total-us 0 :min-us math/inf :max-us 0}))
  (def s (get stats name))
  (put s :count (+ (s :count) 1))
  (put s :total-us (+ (s :total-us) dur-us))
  (when (< dur-us (s :min-us)) (put s :min-us dur-us))
  (when (> dur-us (s :max-us)) (put s :max-us dur-us))
  # Append trace event (Chrome Trace Event "X" format)
  (when (< (length trace-events) max-trace-events)
    (def ev @{:name name
              :cat (span :cat)
              :ph "X"
              :ts (* (- (span :ts) start-time) 1000000)
              :dur dur-us
              :pid 1
              :tid 1})
    (when (span :args) (put ev :args (span :args)))
    (array/push trace-events ev)))

(defn with-span
  "Wrap a function call in a profiling span. Returns the function's result."
  [name cat f]
  (when (not enabled) (break (f)))
  (def id (begin name cat))
  (var result nil)
  (var err-val nil)
  (var errored false)
  (try
    (set result (f))
    ([e]
      (set err-val e)
      (set errored true)))
  (end id)
  (when errored (error err-val))
  result)

(defn with-span-meta
  "Like with-span but attaches args-table as metadata to the trace event."
  [name cat args-table f]
  (when (not enabled) (break (f)))
  (def id (begin name cat))
  # Attach metadata to the span on the stack
  (each s span-stack
    (when (= (s :id) id)
      (put s :args args-table)
      (break)))
  (var result nil)
  (var err-val nil)
  (var errored false)
  (try
    (set result (f))
    ([e]
      (set err-val e)
      (set errored true)))
  (end id)
  (when errored (error err-val))
  result)

(defn get-stats [] stats)

(defn reset
  "Clear all profiling state."
  []
  (set stats @{})
  (array/clear trace-events)
  (array/clear span-stack)
  (set next-span-id 0)
  (set start-time (os/clock))
  (table/clear tool-span-ids))

(defn export-trace
  "Serialize trace events to Chrome Trace Event JSON. Write to path."
  [&opt path]
  (default path
    (string ".gent/profile-" (math/floor (* (os/clock) 1000)) ".json"))
  (os/mkdir ".gent")
  (def payload @{:traceEvents trace-events
                 :displayTimeUnit "ms"
                 :otherData @{:generator "gent-profile"}})
  (spit path (json/encode payload))
  path)

(defn format-stats
  "Return formatted multi-line string of profiling stats."
  []
  (when (empty? stats)
    (break "No profiling data collected."))
  (def elapsed-us (if start-time (* (- (os/clock) start-time) 1000000) 0))
  (def elapsed-s (/ elapsed-us 1000000))
  (def total-events (length trace-events))
  (def header (string/format "Profiling: %.1fs, %d events" elapsed-s total-events))
  (def lines @[header ""
               (string/format "%-24s %5s %10s %9s %9s %9s"
                 "Name" "Count" "Total(ms)" "Avg(ms)" "Min(ms)" "Max(ms)")])
  (def sorted-names (sort (keys stats)))
  (each name sorted-names
    (def s (get stats name))
    (def count (s :count))
    (def total-ms (/ (s :total-us) 1000))
    (def avg-ms (if (> count 0) (/ total-ms count) 0))
    (def min-ms (if (= (s :min-us) math/inf) 0 (/ (s :min-us) 1000)))
    (def max-ms (/ (s :max-us) 1000))
    (array/push lines
      (string/format "%-24s %5d %10.1f %9.1f %9.1f %9.1f"
        name count total-ms avg-ms min-ms max-ms)))
  (string/join lines "\n"))

# ── Tool profiling hooks ──────────────────────────────────────

(defn- make-before-tool-hook []
  (fn [name input]
    (def id (begin (string "tool:" name) "tool"))
    (put tool-span-ids name id)))

(defn- make-after-tool-hook []
  (fn [name input result]
    (def id (get tool-span-ids name))
    (when id
      (end id)
      (put tool-span-ids name nil))))

(defn enable
  "Enable profiling. Registers tool hooks."
  []
  (set enabled true)
  (set start-time (os/clock))
  (set before-tool-hook (make-before-tool-hook))
  (set after-tool-hook (make-after-tool-hook))
  (hooks/add :before-tool-call before-tool-hook)
  (hooks/add :after-tool-call after-tool-hook)
  true)

(defn disable
  "Disable profiling. Removes tool hooks."
  []
  (set enabled false)
  (when before-tool-hook
    (hooks/remove :before-tool-call before-tool-hook)
    (set before-tool-hook nil))
  (when after-tool-hook
    (hooks/remove :after-tool-call after-tool-hook)
    (set after-tool-hook nil))
  true)

# Auto-enable from environment variable
(when (os/getenv "GENT_PROFILE")
  (enable))
