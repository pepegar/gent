(import core/tools :as tools)

(def- default-limit 10)

(defn- walk-dir [dir]
  "Recursively list files and directories under dir (fallback when not in a git repo)."
  (def results @[])
  (each entry (os/dir dir)
    (def full-path (string dir "/" entry))
    (def stat (os/stat full-path))
    (when stat
      (if (= :directory (stat :mode))
        (do
          (array/push results (string full-path "/"))
          (array/concat results (walk-dir full-path)))
        (array/push results full-path))))
  results)

(defn- git-list-files [dir]
  "List non-ignored files using git. Returns nil if not in a git repo."
  (def cmd (string "cd " (if (= dir ".") "." dir)
                   " && git ls-files --cached --others --exclude-standard 2>/dev/null"))
  (def result (process/exec "bash" ["-c" cmd]))
  (when (= 0 (math/round (get result :status)))
    (def stdout (get result :stdout ""))
    (if (= stdout "")
      @[]
      (let [lines (string/split "\n" (string/trimr stdout))
            prefix (if (= dir ".") "" (string dir "/"))]
        (map (fn [l] (string prefix l)) lines)))))

(tools/register "list_files"
  {:description ```List files and directories at the given path. Respects .gitignore when inside a git repository.
Returns a newline-separated list of file paths. When the result is truncated, a message indicates how many files were omitted.
Use the limit parameter to control how many files are returned (default 10).```
   :schema {:type "object"
            :properties {:path {:type "string"
                                :description "Optional relative path to list files from. Defaults to current directory."}
                         :limit {:type "integer"
                                 :description "Maximum number of files to return. Defaults to 10."}}
            :required []}
   :function (fn [input]
               (def dir (or (get input :path) "."))
               (def limit (or (get input :limit) default-limit))
               (def files (or (git-list-files dir) (walk-dir dir)))
               (def total (length files))
               (if (<= total limit)
                 (string/join files "\n")
                 (let [truncated (array/slice files 0 limit)]
                   (string (string/join truncated "\n")
                           "\n\n[Truncated: showing " limit " of " total " files. "
                           "Use a more specific path or increase the limit to see more.]"))))})
