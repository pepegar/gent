(import core/tools :as tools)

# ── Image detection by magic bytes ─────────────────────────────

(def- image-signatures
  "Magic byte signatures for supported image formats."
  [{:bytes "\x89PNG\r\n\x1A\n" :media-type "image/png"}
   {:bytes "\xFF\xD8\xFF"      :media-type "image/jpeg"}
   {:bytes "GIF87a"            :media-type "image/gif"}
   {:bytes "GIF89a"            :media-type "image/gif"}
   {:bytes "RIFF"              :media-type "image/webp" :extra-check :webp}])

(defn- detect-image-type
  "Detect image MIME type from file header bytes. Returns media-type string or nil."
  [path]
  (def f (file/open path :rb))
  (unless f (break nil))
  (defer (file/close f)
    (def header (file/read f 12))
    (unless header (break nil))
    (var result nil)
    (each sig image-signatures
      (when (nil? result)
        (def sig-bytes (sig :bytes))
        (when (>= (length header) (length sig-bytes))
          (var match true)
          (for i 0 (length sig-bytes)
            (when (not= (get header i) (get sig-bytes i))
              (set match false)
              (break)))
          (when match
            # WEBP needs extra check: bytes 8-11 must be "WEBP"
            (if (= :webp (sig :extra-check))
              (when (and (>= (length header) 12)
                         (= (get header 8) (chr "W"))
                         (= (get header 9) (chr "E"))
                         (= (get header 10) (chr "B"))
                         (= (get header 11) (chr "P")))
                (set result (sig :media-type)))
              (set result (sig :media-type)))))))
    result))

(def- max-image-size (* 5 1024 1024))  # 5MB limit for API

(defn- read-image-as-content
  "Read an image file and return an Anthropic image content block (as a table).
   Returns a string error message if the file is too large or encoding fails."
  [path media-type]
  (def stat (os/stat path))
  (when (> (stat :size) max-image-size)
    (break (string "Image file too large (" (math/round (/ (stat :size) 1024 1024)) "MB). Max is 5MB.")))
  # Use base64 command — macOS uses -i flag, Linux reads stdin
  # Try `base64 -i <path>` first (macOS), fall back to `base64 <path>` (Linux/coreutils)
  (var result (process/exec "base64" ["-i" path]))
  (when (not= 0 (math/round (get result :status)))
    (set result (process/exec "base64" [path])))
  (when (not= 0 (math/round (get result :status)))
    (break (string "Failed to base64-encode image: " (get result :stderr ""))))
  (def b64 (string/replace-all "\n" "" (string/trim (get result :stdout ""))))
  @{:type "image"
    :source @{:type "base64"
              :media_type media-type
              :data b64}})

(tools/register "read_file"
  {:description "Read the contents of a file at the given relative path. Use this when you need to see what's inside a file. Do not use this with directory names."
   :schema {:type "object"
            :properties {:path {:type "string"
                                :description "The relative path of a file to read"}}
            :required ["path"]}
   :function (fn [input]
               (def path (get input :path))
               (def media-type (detect-image-type path))
               (if media-type
                 (read-image-as-content path media-type)
                 (slurp path)))})
