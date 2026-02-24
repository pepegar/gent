# test/json.janet — Minimal JSON parser for tests.
#
# Parses JSON strings into Janet values:
#   JSON object  → Janet table @{}
#   JSON array   → Janet array @[]
#   JSON string  → Janet string
#   JSON number  → Janet number
#   JSON true    → true
#   JSON false   → false
#   JSON null    → nil
#
# Only used for testing (the real json/decode is a native Rust function).

(defn- skip-ws [s pos]
  (var p pos)
  (while (and (< p (length s))
              (or (= (s p) (chr " "))
                  (= (s p) (chr "\t"))
                  (= (s p) (chr "\n"))
                  (= (s p) (chr "\r"))))
    (++ p))
  p)

(var- parse-value nil)

(defn- parse-string [s pos]
  # pos points at opening "
  (var p (+ pos 1))
  (def buf @"")
  (while (< p (length s))
    (def ch (s p))
    (if (= ch (chr `\`))
      (do
        (++ p)
        (when (< p (length s))
          (def esc (s p))
          (cond
            (= esc (chr `"`)) (buffer/push-byte buf (chr `"`))
            (= esc (chr `\`)) (buffer/push-byte buf (chr `\`))
            (= esc (chr "/")) (buffer/push-byte buf (chr "/"))
            (= esc (chr "n")) (buffer/push-byte buf (chr "\n"))
            (= esc (chr "r")) (buffer/push-byte buf (chr "\r"))
            (= esc (chr "t")) (buffer/push-byte buf (chr "\t"))
            (= esc (chr "u"))
            (do
              # Parse 4 hex digits
              (def hex-str (string/slice s (+ p 1) (+ p 5)))
              (def code (scan-number (string "0x" hex-str)))
              (when code
                (if (< code 0x80)
                  (buffer/push-byte buf code)
                  (if (< code 0x800)
                    (do
                      (buffer/push-byte buf (bor 0xC0 (brshift code 6)))
                      (buffer/push-byte buf (bor 0x80 (band code 0x3F))))
                    (do
                      (buffer/push-byte buf (bor 0xE0 (brshift code 12)))
                      (buffer/push-byte buf (bor 0x80 (band (brshift code 6) 0x3F)))
                      (buffer/push-byte buf (bor 0x80 (band code 0x3F)))))))
              (set p (+ p 4)))
            (buffer/push-byte buf esc))
          (++ p)))
      (if (= ch (chr `"`))
        (break)
        (do
          (buffer/push-byte buf ch)
          (++ p)))))
  [(string buf) (+ p 1)])

(defn- parse-number [s pos]
  (var p pos)
  (while (and (< p (length s))
              (or (<= (chr "0") (s p) (chr "9"))
                  (= (s p) (chr "."))
                  (= (s p) (chr "-"))
                  (= (s p) (chr "+"))
                  (= (s p) (chr "e"))
                  (= (s p) (chr "E"))))
    (++ p))
  (def num-str (string/slice s pos p))
  [(scan-number num-str) p])

(defn- parse-object [s pos]
  # pos points at {
  (def result @{})
  (var p (skip-ws s (+ pos 1)))
  (when (and (< p (length s)) (= (s p) (chr "}")))
    (break [result (+ p 1)]))
  (while (< p (length s))
    (set p (skip-ws s p))
    (when (and (< p (length s)) (= (s p) (chr "}")))
      (break))
    # Key (must be string)
    (def [key next-p] (parse-string s p))
    (set p (skip-ws s next-p))
    # Skip colon
    (when (and (< p (length s)) (= (s p) (chr ":")))
      (++ p))
    (set p (skip-ws s p))
    # Value
    (def [val val-p] (parse-value s p))
    (put result (keyword key) val)
    (set p (skip-ws s val-p))
    # Skip comma
    (when (and (< p (length s)) (= (s p) (chr ",")))
      (++ p)))
  (when (and (< p (length s)) (= (s p) (chr "}")))
    (++ p))
  [result p])

(defn- parse-array [s pos]
  # pos points at [
  (def result @[])
  (var p (skip-ws s (+ pos 1)))
  (when (and (< p (length s)) (= (s p) (chr "]")))
    (break [result (+ p 1)]))
  (while (< p (length s))
    (set p (skip-ws s p))
    (when (and (< p (length s)) (= (s p) (chr "]")))
      (break))
    (def [val val-p] (parse-value s p))
    (array/push result val)
    (set p (skip-ws s val-p))
    (when (and (< p (length s)) (= (s p) (chr ",")))
      (++ p)))
  (when (and (< p (length s)) (= (s p) (chr "]")))
    (++ p))
  [result p])

(set parse-value
  (fn [s pos]
    (def p (skip-ws s pos))
    (when (>= p (length s)) (break [nil p]))
    (def ch (s p))
    (cond
      (= ch (chr `"`)) (parse-string s p)
      (= ch (chr "{")) (parse-object s p)
      (= ch (chr "[")) (parse-array s p)
      (or (= ch (chr "-")) (<= (chr "0") ch (chr "9")))
      (parse-number s p)
      (string/has-prefix? "true" (string/slice s p))
      [true (+ p 4)]
      (string/has-prefix? "false" (string/slice s p))
      [false (+ p 5)]
      (string/has-prefix? "null" (string/slice s p))
      [nil (+ p 4)]
      [nil p])))

(defn decode
  "Parse a JSON string into Janet values."
  [s]
  (when (or (nil? s) (= "" s)) (break nil))
  (def [val _] (parse-value s 0))
  val)

(defn encode
  "Encode a Janet value as JSON (minimal, for testing)."
  [x]
  (cond
    (nil? x) "null"
    (boolean? x) (if x "true" "false")
    (number? x)
    (if (= (math/floor x) x)
      (string/format "%d" x)
      (string/format "%g" x))
    (string? x)
    (string `"` (string/replace-all "\t" `\t`
                  (string/replace-all "\r" `\r`
                    (string/replace-all "\n" `\n`
                      (string/replace-all `"` `\"`
                        (string/replace-all `\` `\\` x))))) `"`)
    (keyword? x) (encode (string x))
    (buffer? x) (encode (string x))
    (or (array? x) (tuple? x))
    (string "[" (string/join (map encode x) ",") "]")
    (or (table? x) (struct? x))
    (string "{"
      (string/join
        (seq [[k v] :pairs x]
          (string (encode (if (keyword? k) (string k) k)) ":" (encode v)))
        ",")
      "}")
    (string/format "%q" x)))
