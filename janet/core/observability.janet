# core/observability.janet — Session-level observability.
#
# Collects token usage, cost, and tool stats using hooks — no per-function
# annotation needed. The hooks system is the metaprogramming trick.
#
# Data collected per session:
#   - Input/output/cache tokens from actual API usage (not estimates)
#   - Cost (USD) computed from a pricing table keyed by model prefix
#   - Tool call counts and error counts
#   - Turn count and durations
#   - Stop reason distribution
#
# Activation: called automatically from core/agent.janet and core/headless.janet.
#
# Control plane: HTTP server on port 7889 (or GENT_METRICS_PORT).
#   curl http://localhost:7889/metrics

(import core/hooks :as hooks)
(import core/api :as api)

# ── State ─────────────────────────────────────────────────────

(var- session-id nil)
(var- start-time nil)
(var- provider nil)
(var- model nil)
(var- cwd "")

(var- total-input-tokens 0)
(var- total-output-tokens 0)
(var- total-cache-creation 0)
(var- total-cache-read 0)

(var- turn-count 0)
(var- turn-start-time nil)
(var- turn-durations @[])

(var- stop-reason-counts @{})
(var- tool-call-counts @{})
(var- tool-error-counts @{})
(var- tool-start-times @{})

(var- http-listener nil)
(var- http-port nil)
(var- http-pending-conn nil)

# Hook function refs for later removal
(var- after-response-hook nil)
(var- before-tool-call-hook nil)
(var- after-tool-call-hook nil)
(var- before-send-hook nil)
(var- turn-end-hook nil)

# ── Pricing (USD per million tokens) ──────────────────────────

(def- pricing-table
  {"claude-opus-4"   {:input 15.0  :output 75.0  :cache-write 18.75 :cache-read 1.5}
   "claude-sonnet-4" {:input 3.0   :output 15.0  :cache-write 3.75  :cache-read 0.3}
   "claude-haiku-4"  {:input 0.8   :output 4.0   :cache-write 1.0   :cache-read 0.08}})

(defn- find-pricing [model-name]
  (when (nil? model-name) (break nil))
  (var result nil)
  (each [prefix rates] (pairs pricing-table)
    (when (string/has-prefix? prefix model-name)
      (set result rates)
      (break)))
  result)

# ── Helpers ───────────────────────────────────────────────────

(defn- commafy [n]
  (def s (string/format "%d" (math/round n)))
  (def len (length s))
  (when (<= len 3) (break s))
  (def parts @[])
  (var i len)
  (while (> i 0)
    (def start (max 0 (- i 3)))
    (array/insert parts 0 (string/slice s start i))
    (set i start))
  (string/join parts ","))

(defn- fmt-dollars [n] (string/format "$%.3f" n))

(defn- fmt-uptime [seconds]
  (def s (math/floor seconds))
  (def mins (math/floor (/ s 60)))
  (def hours (math/floor (/ mins 60)))
  (cond
    (>= hours 1) (string/format "%dh %dm" hours (% mins 60))
    (>= mins 1) (string/format "%dm %ds" mins (% s 60))
    (string/format "%ds" s)))

# ── Hook bodies (public so tests can call them directly) ───────

(defn process-response
  "Process an API response — updates token and stop-reason counts."
  [response]
  (def usage (response :usage))
  (when usage
    (+= total-input-tokens (or (usage :input_tokens) 0))
    (+= total-output-tokens (or (usage :output_tokens) 0))
    (+= total-cache-creation (or (usage :cache_creation_input_tokens) 0))
    (+= total-cache-read (or (usage :cache_read_input_tokens) 0)))
  (def reason (response :stop_reason))
  (when reason
    (put stop-reason-counts reason
      (+ (or (get stop-reason-counts reason) 0) 1))))

(defn process-before-tool
  "Record that a tool call started."
  [name _input]
  (put tool-call-counts name (+ (or (get tool-call-counts name) 0) 1))
  (put tool-start-times name (os/clock)))

(defn process-after-tool
  "Record that a tool call finished; count errors."
  [name _input result]
  (put tool-start-times name nil)
  (when (and (table? result) (result :error))
    (put tool-error-counts name (+ (or (get tool-error-counts name) 0) 1))))

(defn process-before-send
  "Record turn start time on first send of a turn."
  [_conversation]
  (when (nil? turn-start-time)
    (set turn-start-time (os/clock))))

(defn process-turn-end
  "Record turn duration and increment turn counter."
  []
  (when turn-start-time
    (array/push turn-durations (- (os/clock) turn-start-time))
    (+= turn-count 1)
    (set turn-start-time nil)))

# ── Public API ────────────────────────────────────────────────

(defn get-state
  "Return a snapshot table of all collected observability data."
  []
  (def now (os/clock))
  (def uptime (if start-time (- now start-time) 0))
  (def total-tokens (+ total-input-tokens total-output-tokens
                       total-cache-creation total-cache-read))
  (var sum-dur 0)
  (each d turn-durations (+= sum-dur d))
  (def avg-duration
    (if (> (length turn-durations) 0)
      (/ sum-dur (length turn-durations))
      0))
  (def rates (find-pricing model))
  (def cost
    (when rates
      (def c
        @{:input-cost       (* total-input-tokens    (/ (rates :input)       1000000))
          :output-cost      (* total-output-tokens   (/ (rates :output)      1000000))
          :cache-write-cost (* total-cache-creation  (/ (rates :cache-write) 1000000))
          :cache-read-cost  (* total-cache-read      (/ (rates :cache-read)  1000000))})
      (put c :total-cost (+ (c :input-cost) (c :output-cost)
                            (c :cache-write-cost) (c :cache-read-cost)))
      c))
  (def tools @{})
  (each [name cnt] (pairs tool-call-counts)
    (put tools name @{:calls cnt :errors (or (get tool-error-counts name) 0)}))
  @{:session-id    session-id
    :cwd            cwd
    :provider       provider
    :model          model
    :start-time     start-time
    :uptime-seconds uptime
    :turns          @{:count turn-count :avg-duration avg-duration}
    :tokens         @{:input       total-input-tokens
                      :output      total-output-tokens
                      :cache-write total-cache-creation
                      :cache-read  total-cache-read
                      :total       total-tokens}
    :cost           cost
    :stop-reasons   stop-reason-counts
    :tools          tools})

(defn format-usage
  "Return a human-readable multi-line usage summary."
  []
  (def state (get-state))
  (def lines @[])
  (array/push lines (string "Session: " (or (state :session-id) "(no session)")
                            " (" (fmt-uptime (or (state :uptime-seconds) 0)) ")"))
  (array/push lines (string "Provider: " (or (state :provider) "unknown")
                            " / " (or (state :model) "unknown")))
  (array/push lines "")
  (def tok (state :tokens))
  (array/push lines "Tokens:")
  (array/push lines (string/format "  %-16s %s" "Input:"       (commafy (tok :input))))
  (array/push lines (string/format "  %-16s %s" "Output:"      (commafy (tok :output))))
  (array/push lines (string/format "  %-16s %s" "Cache write:" (commafy (tok :cache-write))))
  (array/push lines (string/format "  %-16s %s" "Cache read:"  (commafy (tok :cache-read))))
  (array/push lines "  ─────────────────────")
  (array/push lines (string/format "  %-16s %s" "Total:"       (commafy (tok :total))))
  (array/push lines "")
  (def cost (state :cost))
  (if cost
    (do
      (array/push lines "Cost (est.):")
      (array/push lines (string/format "  %-16s %s" "Input:"      (fmt-dollars (cost :input-cost))))
      (array/push lines (string/format "  %-16s %s" "Output:"     (fmt-dollars (cost :output-cost))))
      (array/push lines (string/format "  %-16s %s" "Cache read:" (fmt-dollars (cost :cache-read-cost))))
      (array/push lines "  ─────────────────────")
      (array/push lines (string/format "  %-16s %s" "Total:" (fmt-dollars (cost :total-cost))))
      (array/push lines ""))
    (do
      (array/push lines (string "(cost unavailable for model "
                                (or (state :model) "unknown") ")"))
      (array/push lines "")))
  (def turns (state :turns))
  (array/push lines
    (if (> (turns :count) 0)
      (string/format "Turns: %d  (avg %.1fs)" (turns :count) (turns :avg-duration))
      "Turns: 0"))
  (def stop-r (state :stop-reasons))
  (when (not (empty? stop-r))
    (def parts @[])
    (each [reason cnt] (sort (pairs stop-r))
      (array/push parts (string reason "×" cnt)))
    (array/push lines (string "Stop reasons: " (string/join parts "  "))))
  (array/push lines "")
  (def tools (state :tools))
  (var total-calls 0)
  (each [_ v] (pairs tools) (+= total-calls (v :calls)))
  (when (> total-calls 0)
    (array/push lines (string "Tools (" total-calls " calls):"))
    (each [name info] (sort-by |(- (($ 1) :calls)) (pairs tools))
      (def calls (info :calls))
      (def errors (info :errors))
      (array/push lines
        (if (> errors 0)
          (string/format "  %-16s %d calls, %d error%s"
            name calls errors (if (= errors 1) "" "s"))
          (string/format "  %-16s %d calls" name calls)))))
  (string/join lines "\n"))

(defn metrics-json
  "Return JSON-encoded state for the HTTP /metrics endpoint."
  []
  (json/encode (get-state)))

# ── HTTP control plane ────────────────────────────────────────

(defn start-http-server
  "Start the metrics HTTP server. Tries port, then port+1 … port+9."
  [port]
  (var p port)
  (while (< p (+ port 10))
    (def ok
      (try
        (do
          (def listener (net/listen p))
          (if listener
            (do (set http-listener listener) (set http-port p) true)
            false))
        ([_] false)))
    (when ok (break))
    (++ p)))

(defn get-http-port [] http-port)

(defn poll-http
  "Accept one pending HTTP connection and serve /metrics. Call each reactor frame."
  []
  (when (nil? http-listener) (break))
  (when (nil? http-pending-conn)
    (def conn (net/accept http-listener 0))
    (when conn
      (set http-pending-conn conn)))
  (when (nil? http-pending-conn) (break))
  (def conn http-pending-conn)
  (def req-line (net/read-line conn))
  (cond
    (nil? req-line) (break)
    (= :closed req-line)
    (do (net/close conn) (set http-pending-conn nil) (break)))
  (var header (net/read-line conn))
  (while (and (string? header) (> (length (string/trimr header "\r\n")) 0))
    (set header (net/read-line conn)))
  (def is-metrics (string/find "/metrics" req-line))
  (def body (if is-metrics (metrics-json) `{"error":"not found"}`))
  (def status (if is-metrics "200 OK" "404 Not Found"))
  (net/write-raw conn
    (string "HTTP/1.1 " status "\r\n"
            "Content-Type: application/json\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Connection: close\r\n"
            "Content-Length: " (length body) "\r\n"
            "\r\n"
            body))
  (net/close conn)
  (set http-pending-conn nil))

# ── Lifecycle ─────────────────────────────────────────────────

(defn init
  "Initialize observability for a session. Registers hooks and starts HTTP server."
  [sid &opt port]
  (default port
    (or (when-let [e (os/getenv "GENT_METRICS_PORT")] (scan-number e)) 7889))
  (set session-id sid)
  (set start-time (os/clock))
  (set cwd (or (os/cwd) ""))
  (def cfg (api/get-config))
  (set provider (or (cfg :provider) "unknown"))
  (set model (or (cfg :model) "unknown"))
  (set after-response-hook (fn [r] (process-response r)))
  (set before-tool-call-hook (fn [n i] (process-before-tool n i)))
  (set after-tool-call-hook (fn [n i r] (process-after-tool n i r)))
  (set before-send-hook (fn [c] (process-before-send c)))
  (set turn-end-hook (fn [] (process-turn-end)))
  (hooks/add :after-response after-response-hook)
  (hooks/add :before-tool-call before-tool-call-hook)
  (hooks/add :after-tool-call after-tool-call-hook)
  (hooks/add :before-send before-send-hook)
  (hooks/add :turn-end turn-end-hook)
  (start-http-server port))

(defn stop
  "Remove hooks and close the HTTP listener."
  []
  (when http-pending-conn
    (net/close http-pending-conn)
    (set http-pending-conn nil))
  (when http-listener
    (net/close-listener http-listener)
    (set http-listener nil)
    (set http-port nil))
  (when after-response-hook
    (hooks/remove :after-response after-response-hook)
    (set after-response-hook nil))
  (when before-tool-call-hook
    (hooks/remove :before-tool-call before-tool-call-hook)
    (set before-tool-call-hook nil))
  (when after-tool-call-hook
    (hooks/remove :after-tool-call after-tool-call-hook)
    (set after-tool-call-hook nil))
  (when before-send-hook
    (hooks/remove :before-send before-send-hook)
    (set before-send-hook nil))
  (when turn-end-hook
    (hooks/remove :turn-end turn-end-hook)
    (set turn-end-hook nil)))

(defn reset
  "Reset all state and remove hooks. Use between tests."
  []
  (stop)
  (set session-id nil)
  (set start-time nil)
  (set provider nil)
  (set model nil)
  (set cwd "")
  (set total-input-tokens 0)
  (set total-output-tokens 0)
  (set total-cache-creation 0)
  (set total-cache-read 0)
  (set turn-count 0)
  (set turn-start-time nil)
  (set turn-durations @[])
  (set stop-reason-counts @{})
  (set tool-call-counts @{})
  (set tool-error-counts @{})
  (set tool-start-times @{})
  (set http-pending-conn nil))
