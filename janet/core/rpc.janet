# core/rpc.janet — JSON-RPC 2.0 protocol module.
#
# Pure data transformation layer: parse requests, format responses.
# No dependencies on chat, agent, tools, etc.
#
# Reference: https://www.jsonrpc.org/specification

# ── Standard error codes ────────────────────────────────────

(def parse-error -32700)
(def invalid-request -32600)
(def method-not-found -32601)
(def invalid-params -32602)
(def internal-error -32603)

# ── Request parsing ─────────────────────────────────────────

(defn parse-request
  "Parse a JSON-RPC 2.0 request string.
   Returns @{:id ... :method ... :params ...} on success,
   or @{:error @{:code ... :message ...}} on error."
  [json-string]
  (var parsed nil)
  (try
    (set parsed (json/decode json-string))
    ([err]
      (break @{:error @{:code parse-error :message "Parse error"}})))
  (when (nil? parsed)
    (break @{:error @{:code parse-error :message "Parse error"}}))
  (when (not (or (table? parsed) (struct? parsed)))
    (break @{:error @{:code invalid-request :message "Invalid Request"}}))
  (when (not= (get parsed :jsonrpc) "2.0")
    (break @{:error @{:code invalid-request :message "Invalid Request"}}))
  (def method (get parsed :method))
  (when (or (nil? method) (not (string? method)))
    (break @{:error @{:code invalid-request :message "Invalid Request"}}))
  (def params (get parsed :params))
  (when (and (not (nil? params))
             (not (table? params))
             (not (struct? params))
             (not (array? params))
             (not (tuple? params)))
    (break @{:error @{:code invalid-params :message "Invalid params"}}))
  (def result @{:method method})
  (when (not (nil? params))
    (put result :params params))
  (when (has-key? parsed :id)
    (put result :id (get parsed :id)))
  result)

(defn parse-batch
  "Parse a JSON-RPC 2.0 batch request (JSON array of requests).
   Returns an array of parsed results."
  [json-string]
  (var parsed nil)
  (try
    (set parsed (json/decode json-string))
    ([err]
      (break @[@{:error @{:code parse-error :message "Parse error"}}])))
  (when (nil? parsed)
    (break @[@{:error @{:code parse-error :message "Parse error"}}]))
  (when (not (or (array? parsed) (tuple? parsed)))
    (break @[@{:error @{:code invalid-request :message "Invalid Request"}}]))
  (when (empty? parsed)
    (break @[@{:error @{:code invalid-request :message "Invalid Request"}}]))
  (def results @[])
  (each item parsed
    (array/push results (parse-request (json/encode item))))
  results)

# ── Response formatting ─────────────────────────────────────

(defn format-response
  "Format a JSON-RPC 2.0 success response."
  [id result]
  (json/encode @{:jsonrpc "2.0" :id id :result result}))

(defn format-error
  "Format a JSON-RPC 2.0 error response."
  [id code message &opt data]
  (def err @{:code code :message message})
  (when (not (nil? data))
    (put err :data data))
  (json/encode @{:jsonrpc "2.0" :id id :error err}))

(defn format-notification
  "Format a JSON-RPC 2.0 notification (no id field)."
  [method params]
  (json/encode @{:jsonrpc "2.0" :method method :params params}))

# ── Utilities ───────────────────────────────────────────────

(defn notification?
  "Returns true if the parsed request is a notification (no id field)."
  [request]
  (not (has-key? request :id)))
