(import core/tools :as tools)
(import core/buffers :as buffers)

(defn- edit-file-impl [input]
  (def path (get input :path))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))

  (unless path
    (error "path is required"))

  (when (= old-str new-str)
    (error "old_str and new_str must be different"))

  # If file doesn't exist and old_str is empty, create a new file
  (unless (os/stat path)
    (if (= "" old-str)
      (do
        (def buf (buffers/open path))
        (buffers/insert buf 0 new-str)
        (buffers/save buf)
        (break (string "Created file " path)))
      (error (string "file not found: " path))))

  # Open into buffer, replace, save
  (def buf (buffers/open path))
  (buffers/replace-all buf old-str new-str)
  (buffers/save buf)
  "OK")

(tools/register "edit_file"
  {:description ```Make edits to a text file. Replaces 'old_str' with 'new_str' in the given file.
   'old_str' and 'new_str' MUST be different from each other.
   If the file doesn't exist and old_str is empty, the file will be created with new_str as content.```
   :schema {:type "object"
            :properties {:path {:type "string"
                                :description "The path to the file"}
                         :old_str {:type "string"
                                   :description "Text to search for — must match exactly"}
                         :new_str {:type "string"
                                   :description "Text to replace old_str with"}}
            :required ["path" "old_str" "new_str"]}
   :function edit-file-impl})
