# AGENTS.md support — loads project instructions for the agent.
# See https://agents.md/ for the format specification.
#
# AGENTS.md is a plain Markdown file placed in the directory tree.
# Unlike skills (activated on demand), AGENTS.md content is always
# injected into the system prompt as project context.
#
# Discovery walks from cwd up to /, collecting all AGENTS.md files.
# Closest file comes first (most specific), ancestors follow.

(var- files @[])

(defn- parent-dir
  "Return the parent directory of dir, or nil if at root."
  [dir]
  (if (= "/" dir) nil
    (do
      (def parts (string/split "/" dir))
      (def parent-parts (array/slice parts 0 -2))
      (def parent (string/join parent-parts "/"))
      (if (= "" parent) "/" parent))))

(defn discover
  "Walk from cwd to /, collecting all AGENTS.md files. Closest first."
  []
  (array/clear files)
  (var dir (os/cwd))
  (while dir
    (def candidate (string dir "/AGENTS.md"))
    (when (os/stat candidate)
      (array/push files candidate))
    (set dir (parent-dir dir)))
  files)

(defn list-files
  "Return the list of discovered AGENTS.md paths (closest first)."
  []
  (array/slice files))

(defn count-files
  "Return the number of discovered AGENTS.md files."
  []
  (length files))

(defn system-prompt-snippet
  "Generate the system prompt section with all AGENTS.md content.
   Closest file first, each labeled with its path."
  []
  (when (empty? files)
    (break ""))
  (def parts @[""
               "## Project Instructions (AGENTS.md)"
               ""])
  (each path files
    (def content (try (slurp path) ([_] nil)))
    (when content
      (when (> (length files) 1)
        (array/push parts (string "### From " path))
        (array/push parts ""))
      (array/push parts (string/trim content))
      (array/push parts "")))
  (string/join parts "\n"))
