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
               (def proc (os/spawn ["parinfer-rust" "-m" "paren" "-l" "janet"]
                                   :p {:in :pipe :out :pipe}))
               (:write (proc :in) content)
               (:close (proc :in))
               (def out @"")
               (var chunk (:read (proc :out) 4096))
               (while chunk
                 (buffer/push out chunk)
                 (set chunk (:read (proc :out) 4096)))
               (os/proc-wait proc)
               (def formatted (string out))
               (if (= content formatted)
                 (string path " is already well-formatted")
                 (do
                   (spit path formatted)
                   (string "Formatted " path " with parinfer (paren mode)"))))})
