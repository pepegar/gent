# test/test-rpc.janet — Tests for core/rpc (JSON-RPC 2.0 protocol).

(import test/fake-http :as fake)
(fake/install (curenv))
(var env (curenv))
(while (table/getproto env)
  (set env (table/getproto env)))
(fake/install env)

(import core/rpc :as rpc)
(import test/helper :as t)

(print "── core/rpc ──")

# ── parse-request ────────────────────────────────────────────

(t/test "parse valid request with id, method, params" (fn []
                                                       (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"subtract","params":{"a":1,"b":2},"id":1}`))
                                                       (t/assert= (req :method) "subtract")
                                                       (t/assert= (req :id) 1)
                                                       (t/assert= (get-in req [:params :a]) 1)
                                                       (t/assert= (get-in req [:params :b]) 2)))

(t/test "parse valid request with array params" (fn []
                                                 (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"subtract","params":[42,23],"id":1}`))
                                                 (t/assert= (req :method) "subtract")
                                                 (t/assert= (get (req :params) 0) 42)
                                                 (t/assert= (get (req :params) 1) 23)))

(t/test "parse valid notification (no id)" (fn []
                                            (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"update","params":[1,2,3]}`))
                                            (t/assert= (req :method) "update")
                                            (t/assert-falsy (has-key? req :id))))

(t/test "parse request with no params" (fn []
                                        (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"foobar","id":"1"}`))
                                        (t/assert= (req :method) "foobar")
                                        (t/assert= (req :id) "1")
                                        (t/assert-falsy (has-key? req :params))))

(t/test "parse request with null id treated as notification" (fn []
                                                              (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"test","id":null}`))
                                                              (t/assert= (req :method) "test")
                                                              (t/assert-truthy (rpc/notification? req))))

(t/test "parse invalid JSON returns parse error" (fn []
                                                  (def req (rpc/parse-request "totally broken"))
                                                  (t/assert-truthy (req :error))
                                                  (t/assert= (get-in req [:error :code]) rpc/parse-error)))

(t/test "parse empty string returns parse error" (fn []
                                                  (def req (rpc/parse-request ""))
                                                  (t/assert-truthy (req :error))
                                                  (t/assert= (get-in req [:error :code]) rpc/parse-error)))

(t/test "parse request missing jsonrpc field returns invalid request" (fn []
                                                                       (def req (rpc/parse-request `{"method":"test","id":1}`))
                                                                       (t/assert-truthy (req :error))
                                                                       (t/assert= (get-in req [:error :code]) rpc/invalid-request)))

(t/test "parse request with wrong jsonrpc version returns invalid request" (fn []
                                                                            (def req (rpc/parse-request `{"jsonrpc":"1.0","method":"test","id":1}`))
                                                                            (t/assert-truthy (req :error))
                                                                            (t/assert= (get-in req [:error :code]) rpc/invalid-request)))

(t/test "parse request missing method returns invalid request" (fn []
                                                                (def req (rpc/parse-request `{"jsonrpc":"2.0","id":1}`))
                                                                (t/assert-truthy (req :error))
                                                                (t/assert= (get-in req [:error :code]) rpc/invalid-request)))

(t/test "parse request with non-string method returns invalid request" (fn []
                                                                        (def req (rpc/parse-request `{"jsonrpc":"2.0","method":42,"id":1}`))
                                                                        (t/assert-truthy (req :error))
                                                                        (t/assert= (get-in req [:error :code]) rpc/invalid-request)))

(t/test "parse non-object JSON returns invalid request" (fn []
                                                         (def req (rpc/parse-request `[1,2,3]`))
                                                         (t/assert-truthy (req :error))
                                                         (t/assert= (get-in req [:error :code]) rpc/invalid-request)))

# ── notification? ────────────────────────────────────────────

(t/test "notification? returns true for notification" (fn []
                                                       (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"update","params":[]}`))
                                                       (t/assert-truthy (rpc/notification? req))))

(t/test "notification? returns false for request with id" (fn []
                                                           (def req (rpc/parse-request `{"jsonrpc":"2.0","method":"test","id":1}`))
                                                           (t/assert-falsy (rpc/notification? req))))

# ── format-response ──────────────────────────────────────────

(t/test "format success response" (fn []
                                   (def resp (json/decode (rpc/format-response 1 "hello")))
                                   (t/assert= (resp :jsonrpc) "2.0")
                                   (t/assert= (resp :id) 1)
                                   (t/assert= (resp :result) "hello")))

(t/test "format success response with table result" (fn []
                                                     (def resp (json/decode (rpc/format-response 1 @{:sum 42})))
                                                     (t/assert= (resp :jsonrpc) "2.0")
                                                     (t/assert= (resp :id) 1)
                                                     (t/assert= (get-in resp [:result :sum]) 42)))

(t/test "format success response with null id" (fn []
                                                (def resp (json/decode (rpc/format-response nil "result")))
                                                (t/assert= (resp :jsonrpc) "2.0")
                                                (t/assert= (resp :result) "result")))

# ── format-error ─────────────────────────────────────────────

(t/test "format error response" (fn []
                                 (def resp (json/decode (rpc/format-error 1 rpc/method-not-found "Method not found")))
                                 (t/assert= (resp :jsonrpc) "2.0")
                                 (t/assert= (resp :id) 1)
                                 (t/assert= (get-in resp [:error :code]) rpc/method-not-found)
                                 (t/assert= (get-in resp [:error :message]) "Method not found")))

(t/test "format error response with data" (fn []
                                           (def resp (json/decode (rpc/format-error 1 rpc/internal-error "Internal error" @{:detail "stack trace"})))
                                           (t/assert= (get-in resp [:error :code]) rpc/internal-error)
                                           (t/assert= (get-in resp [:error :data :detail]) "stack trace")))

(t/test "format error response without data" (fn []
                                              (def resp (json/decode (rpc/format-error 1 rpc/invalid-params "Invalid params")))
                                              (t/assert= (get-in resp [:error :code]) rpc/invalid-params)
                                              (t/assert-falsy (has-key? (resp :error) :data))))

# ── format-notification ──────────────────────────────────────

(t/test "format notification" (fn []
                               (def resp (json/decode (rpc/format-notification "update" @{:value 42})))
                               (t/assert= (resp :jsonrpc) "2.0")
                               (t/assert= (resp :method) "update")
                               (t/assert= (get-in resp [:params :value]) 42)
                               (t/assert-falsy (has-key? resp :id))))

(t/test "format notification with array params" (fn []
                                                 (def resp (json/decode (rpc/format-notification "log" @[1 2 3])))
                                                 (t/assert= (resp :jsonrpc) "2.0")
                                                 (t/assert= (resp :method) "log")))

# ── parse-batch ──────────────────────────────────────────────

(t/test "parse batch request" (fn []
                               (def results (rpc/parse-batch `[{"jsonrpc":"2.0","method":"a","id":1},{"jsonrpc":"2.0","method":"b","id":2}]`))
                               (t/assert= (length results) 2)
                               (t/assert= ((results 0) :method) "a")
                               (t/assert= ((results 1) :method) "b")))

(t/test "parse batch with mixed valid and invalid" (fn []
                                                    (def results (rpc/parse-batch `[{"jsonrpc":"2.0","method":"ok","id":1},{"jsonrpc":"1.0","method":"bad","id":2}]`))
                                                    (t/assert= (length results) 2)
                                                    (t/assert= ((results 0) :method) "ok")
                                                    (t/assert-truthy (get-in results [1 :error]))))

(t/test "parse empty batch returns error" (fn []
                                           (def results (rpc/parse-batch `[]`))
                                           (t/assert= (length results) 1)
                                           (t/assert-truthy (get-in results [0 :error]))))

(t/test "parse invalid JSON batch returns error" (fn []
                                                  (def results (rpc/parse-batch `not json`))
                                                  (t/assert= (length results) 1)
                                                  (t/assert= (get-in results [0 :error :code]) rpc/parse-error)))

(t/test "parse non-array batch returns error" (fn []
                                               (def results (rpc/parse-batch `{"jsonrpc":"2.0","method":"test","id":1}`))
                                               (t/assert= (length results) 1)
                                               (t/assert= (get-in results [0 :error :code]) rpc/invalid-request)))

# ── Round-trip tests ─────────────────────────────────────────

(t/test "round-trip: format response then parse as JSON" (fn []
                                                          (def json-str (rpc/format-response 42 @{:status "ok"}))
                                                          (def parsed (json/decode json-str))
                                                          (t/assert= (parsed :jsonrpc) "2.0")
                                                          (t/assert= (parsed :id) 42)
                                                          (t/assert= (get-in parsed [:result :status]) "ok")))

(t/test "round-trip: format error then parse as JSON" (fn []
                                                       (def json-str (rpc/format-error 1 rpc/method-not-found "Not found"))
                                                       (def parsed (json/decode json-str))
                                                       (t/assert= (parsed :jsonrpc) "2.0")
                                                       (t/assert= (parsed :id) 1)
                                                       (t/assert= (get-in parsed [:error :code]) rpc/method-not-found)))

# ── Error code constants ─────────────────────────────────────

(t/test "error code constants" (fn []
                                (t/assert= rpc/parse-error -32700)
                                (t/assert= rpc/invalid-request -32600)
                                (t/assert= rpc/method-not-found -32601)
                                (t/assert= rpc/invalid-params -32602)
                                (t/assert= rpc/internal-error -32603)))

(def pass (t/pass))
(def fail (t/fail))
