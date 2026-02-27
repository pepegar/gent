# Project configuration for gent development
# Registers development tools available in the gent session.

(import core/tools :as tools)

(tools/register "parinfer"
  {:description ```Run parinfer on a Janet file to fix indentation and parentheses.
Uses paren mode: adjusts indentation to match existing parentheses.
Requires parinfer-rust to be on PATH (available via nix develop).```
   :schema {:type "object"
            :properties {:path {:type "string"
                                :description "Path to the .janet file to format"}}
            :required ["path"]}
   :function (fn [input]
               (def path (get input :path))
               (unless (os/stat path)
                 (error (string "file not found: " path)))
               (def content (slurp path))
               (def result (process/exec "bash" ["-c" (string "parinfer-rust -m paren -l janet --no-janet-long-strings < " (string/format "%q" path))]))
               (when (not= 0 (get result :status))
                 (def err (string (get result :stderr) (get result :stdout)))
                 (error (string "parinfer-rust failed: " (string/trim err))))
               (def formatted (get result :stdout))
               (if (= content formatted)
                 (string path " is already well-formatted")
                 (do
                   (spit path formatted)
                   (string "Formatted " path " with parinfer (paren mode)"))))})
