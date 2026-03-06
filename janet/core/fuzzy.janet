# core/fuzzy.janet — Fuzzy matching (zf-style, lower score = better).
#
# Multi-start subsequence matching adapted from natecraddock/zf.
#   - Tries every occurrence of the first query char, keeps best alignment
#   - Word boundaries (/ _ - . space) reduce penalties
#   - Consecutive matches are cheap (first +1.0, rest free)
#   - Gaps penalized by distance + 2.0 if not at a word boundary

(defn- word-boundary? [byte]
  (case byte
    (chr "/") true
    (chr "_") true
    (chr "-") true
    (chr ".") true
    (chr " ") true
    false))

(defn- scan-to-end
  "Try to match remaining token chars left-to-right from start-idx.
   Returns {:rank <float> :matches [...]} or nil. Lower rank = better."
  [str token start-idx]
  (var rank 1.0)
  (def matches @[start-idx])

  (when (and (> start-idx 0)
             (not (word-boundary? (get str (- start-idx 1)))))
    (+= rank 2.0))

  (var last-idx start-idx)
  (var last-sequential false)
  (var failed false)

  (for i 0 (length token)
    (def ch (get token i))
    (var found-idx nil)
    (for j (+ last-idx 1) (length str)
      (when (= ch (get str j))
        (set found-idx j)
        (break)))
    (when (nil? found-idx)
      (set failed true)
      (break))

    (if (= found-idx (+ last-idx 1))
      (do
        (when (not last-sequential)
          (set last-sequential true)
          (+= rank 1.0)))
      (do
        (set last-sequential false)
        (when (not (word-boundary? (get str (- found-idx 1))))
          (+= rank 2.0))
        (+= rank (- found-idx last-idx))))

    (array/push matches found-idx)
    (set last-idx found-idx))

  (if failed nil {:rank rank :matches matches}))

(defn score
  "Calculate fuzzy match score for target against query.
   Returns {:score <number> :matches [pos1 pos2 ...]} or nil if no match.
   Lower score is better."
  [target query]
  (when (empty? target) (break nil))
  (when (empty? query) (break {:score math/inf :matches @[]}))

  (def ltarget (string/ascii-lower target))
  (def lquery (string/ascii-lower query))
  (def first-char (get lquery 0))
  (def rest-query (string/slice lquery 1))

  (var best nil)

  (for i 0 (length ltarget)
    (when (= (get ltarget i) first-char)
      (def result (scan-to-end ltarget rest-query i))
      (when result
        (when (or (nil? best) (< (result :rank) (best :rank)))
          (set best result)))))

  (when (nil? best) (break nil))
  {:score (best :rank) :matches (best :matches)})

(defn filter-sort
  "Filter items by fuzzy query, return sorted array of {:item <original> :score <result>}.
   Empty query returns all items (unscored)."
  [items query]
  (if (or (nil? query) (= "" query))
    (map |(do {:item $ :score nil}) items)
    (do
      (def results @[])
      (each item items
        (def s (score item query))
        (when s
          (array/push results {:item item :score s})))
      (sort-by |(get-in $ [:score :score] math/inf) results))))