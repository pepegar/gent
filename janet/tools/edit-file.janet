(import core/tools :as tools)

(defn- create-file [path content]
  "Create a new file, including parent directories."
  # Create parent directories if needed
  (def parts (string/split "/" path))
  (when (> (length parts) 1)
    (def dir (string/join (array/slice parts 0 -2) "/"))
    (os/mkdir dir))
  (spit path content)
  (string "Created file " path))

(defn- edit-file-impl [input]
  (def path (get input :path))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))

  (unless path
    (error "path is required"))

  (when (= old-str new-str)
    (error "old_str and new_str must be different"))

  # If file doesn't exist and old_str is empty, create it
  (unless (os/stat path)
    (if (= "" old-str)
      (break (create-file path new-str))
      (error (string "file not found: " path))))

  # Read, replace, write
  (def content (slurp path))
  (def new-content (string/replace-all old-str new-str content))

  (when (and (= content new-content) (not= "" old-str))
    (error "old_str not found in file"))

  (spit path new-content)
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
