(import core/tools :as tools)
(import core/buffers :as buffers)
(import widgets/chat :as chat)

(defn- edit-file-impl [input]
  (def path (get input :path))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))

  (unless path
    (error "path is required"))

  (when (= old-str new-str)
    (error "old_str and new_str must be different"))

  # Check if this is a large operation that might need progress feedback
  (def total-size (+ (length old-str) (length new-str)))
  (def is-large-op (> total-size 5000))  # 5KB threshold
  
  # Provide immediate feedback for large operations
  (when is-large-op
    (def size-kb (math/floor (/ total-size 1024)))
    (chat/output-info (string "Processing edit (" size-kb "KB)..."))
    # Force UI update to show the progress message immediately
    (import core/widget :as widget)
    (widget/mark-dirty :chat))

  # If file doesn't exist and old_str is empty, create a new file
  (unless (os/stat path)
    (if (= "" old-str)
      (do
        (when is-large-op (chat/output-info "Creating new file..."))
        (def buf (buffers/open path))
        (buffers/insert buf 0 new-str)
        (buffers/save buf)
        (break (string "Created file " path)))
      (error (string "file not found: " path))))

  # For large operations, show what we're doing
  (when is-large-op
    (chat/output-info "Loading file into buffer...")
    (widget/mark-dirty :chat))

  # Open into buffer, replace, save
  (def buf (buffers/open path))
  
  (when is-large-op
    (chat/output-info "Performing text replacement...")
    (widget/mark-dirty :chat))
  
  (buffers/replace-all buf old-str new-str)
  
  (when is-large-op
    (chat/output-info "Saving changes...")
    (widget/mark-dirty :chat))
  
  (buffers/save buf)
  "OK")

(defn- edit-file-async [input]
  "Async version for large edits with progress feedback"
  (def path (get input :path))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))
  
  (var progress-step 0)
  (def total-steps 4)
  
  (defn poll []
    (++ progress-step)
    (cond
      (= progress-step 1)
      (do
        (chat/output-info (string "Step 1/" total-steps ": Validating " path "..."))
        nil) # not done yet
        
      (= progress-step 2)
      (do
        (chat/output-info (string "Step 2/" total-steps ": Loading file into buffer..."))
        (unless (os/stat path)
          (if (not= "" old-str)
            (break [:error (string "file not found: " path)])))
        nil)
        
      (= progress-step 3)
      (do
        (chat/output-info (string "Step 3/" total-steps ": Processing replacement..."))
        (try
          (do
            (def buf (buffers/open path))
            (if (= "" old-str)
              (buffers/insert buf 0 new-str)
              (buffers/replace-all buf old-str new-str))
            nil) # continue
          ([err] [:error (string "Edit failed: " err)])))
          
      (= progress-step 4)
      (do
        (chat/output-info (string "Step 4/" total-steps ": Saving changes..."))
        (try
          (do
            (def buf (buffers/get-buf path))
            (when buf (buffers/save buf))
            [:done "OK"])
          ([err] [:error (string "Save failed: " err)])))
          
      [:error "Unexpected progress step"]))
  
  (defn cancel []
    (chat/output-info "Edit operation cancelled"))
  
  (tools/async-tool poll cancel))

(tools/register "edit_file"
  {:description ```Make edits to a text file. Replaces 'old_str' with 'new_str' in the given file.
'old_str' and 'new_str' MUST be different from each other.
If the file doesn't exist and old_str is empty, the file will be created with new_str as content.
For large files (>8KB), provides async progress feedback.```
   :schema {:type "object"
            :properties {:path {:type "string"
                                :description "The path to the file"}
                         :old_str {:type "string"
                                   :description "Text to search for — must match exactly"}
                         :new_str {:type "string"
                                   :description "Text to replace old_str with"}}
            :required ["path" "old_str" "new_str"]}
   :function edit-file-impl})
