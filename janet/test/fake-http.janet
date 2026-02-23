# test/fake-http.janet — Mock native functions for headless testing.
#
# Replaces native http/*, json/*, term/*, and process/* functions with
# fakes so the full widget stack can be imported and tested without
# the Rust runtime.
#
# Usage (must be called BEFORE importing any gent modules):
#   (import test/fake-http :as fake)
#   (fake/install)
#   (fake/queue-lines @["data: ..." "data: ..."])
#   # ... now import widgets/chat, etc. ...
#   (fake/reset)

# ── Helpers ────────────────────────────────────────────────────

(defn- install-mock
  "Put a mock function into the caller's environment."
  [env name f]
  (put env (symbol name) @{:value f}))

# ── Stream response queue ──────────────────────────────────────
# Each stream-start call pops the next response from the queue.
# A response is an array of values: string lines, :done, or error tables.

(var- response-queue @[])
(var- active-streams @{})
(var- next-stream-id 1)
(var- last-request @{})

(defn queue-lines
  "Queue an array of SSE lines for the next stream-start call.
   :done is appended automatically."
  [lines]
  (def q (array/slice lines))
  (when (or (empty? q) (not= :done (last q)))
    (array/push q :done))
  (array/push response-queue q))

(defn get-last-request
  "Return the last HTTP request made (method, url, headers, body)."
  []
  last-request)

(defn reset
  "Clear all queued responses and active streams."
  []
  (array/clear response-queue)
  (set active-streams @{})
  (set next-stream-id 1)
  (set last-request @{}))

# ── HTTP mocks ─────────────────────────────────────────────────

(defn- mock-stream-start [method url headers body]
  (set last-request @{:method method :url url :headers headers :body body})
  (def id next-stream-id)
  (++ next-stream-id)
  # Pop the next queued response, or default to immediate :done
  (def lines
    (if (not (empty? response-queue))
      (do (def first-resp (first response-queue))
          (array/remove response-queue 0)
          first-resp)
      @[:done]))
  # Reverse so we can pop from the end (FIFO)
  (put active-streams id (reverse lines))
  id)

(defn- mock-stream-read [stream-id]
  (def q (get active-streams stream-id))
  (if (or (nil? q) (empty? q))
    :done
    (array/pop q)))

(defn- mock-stream-stop [stream-id]
  (put active-streams stream-id nil)
  nil)

(defn- mock-stream [method url headers body callback]
  (set last-request @{:method method :url url :headers headers :body body})
  (def id (mock-stream-start method url headers body))
  (var keep-going true)
  (while keep-going
    (def line (mock-stream-read id))
    (cond
      (nil? line) (set keep-going false)
      (= :done line) (set keep-going false)
      (string? line) (callback line)
      (set keep-going false)))
  nil)

(defn- mock-request [method url headers body]
  (set last-request @{:method method :url url :headers headers :body body})
  nil)

# ── JSON mocks ─────────────────────────────────────────────────

(import test/json :as json-impl)

(defn- mock-json-encode [x]
  (json-impl/encode x))

(defn- mock-json-decode [s]
  (json-impl/decode s))

# ── Term mocks ─────────────────────────────────────────────────

(var- mock-term-cols 80)
(var- mock-term-rows 24)
(var- mock-term-output @"")

(defn set-term-size
  "Configure the fake terminal dimensions."
  [cols rows]
  (set mock-term-cols cols)
  (set mock-term-rows rows))

(defn get-term-output
  "Return everything written via term/write."
  []
  (string mock-term-output))

(defn clear-term-output
  "Clear the term/write capture buffer."
  []
  (buffer/clear mock-term-output))

(defn- mock-term-write [s] (buffer/push mock-term-output s) nil)
(defn- mock-term-size [] @{:cols mock-term-cols :rows mock-term-rows})
(defn- mock-term-enable-raw [] true)
(defn- mock-term-disable-raw [] nil)
(defn- mock-term-read-event [&opt timeout] nil)
(defn- mock-term-suspend [] true)

# ── Process mock ───────────────────────────────────────────────

(var- process-handler nil)

(defn set-process-handler
  "Set a custom handler for process/exec calls.
   (fn [cmd args] @{:stdout ... :stderr ... :status ...})"
  [f]
  (set process-handler f))

(defn- mock-process-exec [cmd & rest]
  (def args (if (not (empty? rest)) (first rest) @[]))
  (if process-handler
    (process-handler cmd args)
    @{:stdout "" :stderr "" :status 0}))

# ── Install ────────────────────────────────────────────────────

(defn install
  "Install all mocks into the given environment (or caller's env).
   Must be called BEFORE importing modules that use native functions."
  [&opt env]
  (default env (curenv))
  (install-mock env "http/stream-start" mock-stream-start)
  (install-mock env "http/stream-read" mock-stream-read)
  (install-mock env "http/stream-stop" mock-stream-stop)
  (install-mock env "http/stream" mock-stream)
  (install-mock env "http/request" mock-request)
  (install-mock env "json/encode" mock-json-encode)
  (install-mock env "json/decode" mock-json-decode)
  (install-mock env "term/write" mock-term-write)
  (install-mock env "term/size" mock-term-size)
  (install-mock env "term/enable-raw-mode" mock-term-enable-raw)
  (install-mock env "term/disable-raw-mode" mock-term-disable-raw)
  (install-mock env "term/read-event" mock-term-read-event)
  (install-mock env "term/suspend" mock-term-suspend)
  (install-mock env "process/exec" mock-process-exec)
  nil)
