# Skill registry — discovers and loads Agent Skills (agentskills.io spec).
#
# Skills are directories containing a SKILL.md file with YAML frontmatter.
# Progressive disclosure:
#   1. Metadata (~100 tokens): name + description loaded at startup
#   2. Instructions (<5000 tokens): full SKILL.md body loaded on activation
#   3. Resources (as needed): scripts/, references/, assets/ loaded on demand
#
# Search paths (in order, walking up from cwd to /):
#   - .gent/skills/
#   - .agents/skills/
#   - GENT_SKILLS_PATH  (colon-separated, if set)

(var- skill-paths @[])
(var- skills @{})

# ── Search path setup ──────────────────────────────────────────

(defn add-path
  "Add a directory to the skill search paths."
  [path]
  (array/push skill-paths path))

(defn- parent-dir
  "Return the parent directory of dir, or nil if at root."
  [dir]
  (if (= "/" dir) nil
    (do
      (def parts (string/split "/" dir))
      (def parent-parts (array/slice parts 0 -2))
      (def parent (string/join parent-parts "/"))
      (if (= "" parent) "/" parent))))

(defn- walk-ancestors
  "Walk from cwd up to /, collecting existing subdir paths matching name."
  [subdir]
  (def results @[])
  (var dir (os/cwd))
  (while dir
    (def candidate (string dir "/" subdir))
    (when (os/stat candidate)
      (array/push results candidate))
    (set dir (parent-dir dir)))
  # Reverse: ancestors first (/ → cwd), so project-local wins on conflict
  (reverse results))

(defn init-paths
  "Set up default skill search paths.
   Walks from cwd up to / looking for .gent/skills and .agents/skills."
  []
  (array/clear skill-paths)
  # Walk ancestors for .gent/skills and .agents/skills
  (array/concat skill-paths (walk-ancestors ".gent/skills"))
  (array/concat skill-paths (walk-ancestors ".agents/skills"))
  # GENT_SKILLS_PATH env var (colon-separated)
  (def env-path (os/getenv "GENT_SKILLS_PATH"))
  (when env-path
    (each p (string/split ":" env-path)
      (def trimmed (string/trim p))
      (when (and (not= "" trimmed) (os/stat trimmed))
        (array/push skill-paths trimmed))))
  skill-paths)

# ── YAML frontmatter parser ───────────────────────────────────
# Handles the subset of YAML used by SKILL.md:
#   - Simple key: value pairs
#   - Quoted string values
#   - One-level nested maps (metadata:)

(defn- strip-quotes
  "Remove surrounding quotes from a string value."
  [s]
  (if (and (>= (length s) 2)
           (or (and (= (chr "\"") (s 0)) (= (chr "\"") (s (- (length s) 1))))
               (and (= (chr "'") (s 0)) (= (chr "'") (s (- (length s) 1))))))
    (string/slice s 1 -2)
    s))

(defn- indented? [line]
  "Check if a line starts with whitespace (nested YAML value)."
  (and (> (length line) 0)
       (or (= (chr " ") (line 0))
           (= (chr "\t") (line 0)))))

(defn- parse-kv [line]
  "Parse a 'key: value' line. Returns [key value] or nil."
  (def idx (string/find ":" line))
  (when idx
    (def key (string/trim (string/slice line 0 idx)))
    (def rest (string/slice line (+ idx 1)))
    (def value (string/trim rest))
    [key value]))

(defn parse-frontmatter
  "Parse YAML frontmatter from SKILL.md content. Returns [metadata body] or [nil content]."
  [text]
  (def lines (string/split "\n" text))

  # Must start with ---
  (when (or (empty? lines) (not= "---" (string/trim (first lines))))
    (break [nil text]))

  # Find closing ---
  (var end-idx nil)
  (for i 1 (length lines)
    (when (= "---" (string/trim (get lines i)))
      (set end-idx i)
      (break)))

  (unless end-idx
    (break [nil text]))

  # Parse YAML between the fences
  (def meta @{})
  (var current-map-key nil)

  (for i 1 end-idx
    (def line (get lines i))
    (def trimmed (string/trim line))

    # Process non-empty, non-comment lines
    (when (and (not= "" trimmed)
               (not= (chr "#") (trimmed 0)))
      (cond
        # Indented line → nested map value
        (and current-map-key (indented? line))
        (let [kv (parse-kv trimmed)]
          (when kv
            (def [k v] kv)
            (put (get meta current-map-key) k (strip-quotes v))))

        # Top-level key: value
        (let [kv (parse-kv line)]
          (when kv
            (def [k v] kv)
            (set current-map-key nil)
            (if (= "" v)
              # Empty value → start of nested map
              (do
                (put meta k @{})
                (set current-map-key k))
              # Simple value
              (put meta k (strip-quotes v))))))))

  # Body is everything after the closing ---
  (def body-lines (array/slice lines (+ end-idx 1)))
  (def body (string/join body-lines "\n"))

  [meta body])

# ── Skill name validation (per agentskills.io spec) ───────────

(def- name-peg
  "PEG that matches valid skill names: lowercase alphanumeric + hyphens, no leading/trailing/consecutive hyphens."
  ~(* (range "az" "09") (any (+ (range "az" "09") (* "-" (range "az" "09")))) -1))

(defn- valid-name?
  "Check if a skill name meets the spec constraints."
  [name]
  (and
    (string? name)
    (>= (length name) 1)
    (<= (length name) 64)
    (truthy? (peg/match name-peg name))))

# ── Discovery ─────────────────────────────────────────────────

(defn discover
  "Scan all skill paths and load metadata for valid skills."
  []
  (table/clear skills)
  (each search-path skill-paths
    (when (os/stat search-path)
      (each entry (try (os/dir search-path) ([_] @[]))
        (def skill-dir (string search-path "/" entry))
        (def stat (os/stat skill-dir))
        (when (and stat (= :directory (get stat :mode)))
          (def skill-md (string skill-dir "/SKILL.md"))
          (when (os/stat skill-md)
            (def content (slurp skill-md))
            (def [meta body] (parse-frontmatter content))
            (when (and meta (get meta "name") (get meta "description"))
              (def name (get meta "name"))
              # Validate: name is valid AND matches directory name
              (when (and (valid-name? name) (= name entry))
                (put skills name
                  @{:name name
                    :description (get meta "description")
                    :path skill-dir
                    :license (get meta "license")
                    :compatibility (get meta "compatibility")
                    :metadata (get meta "metadata")
                    :allowed-tools (get meta "allowed-tools")
                    :body body}))))))))
  skills)

# ── Public API ─────────────────────────────────────────────────

(defn list-skills
  "Return array of {:name :description :path} for all discovered skills."
  []
  (seq [[name skill] :pairs skills]
    {:name name :description (skill :description) :path (skill :path)}))

(defn get-skill
  "Return full skill data for the given name, or nil."
  [name]
  (get skills name))

(defn load-skill
  "Activate a skill: return its body + path for resolving file references. Returns nil if not found."
  [name]
  (if-let [skill (get skills name)]
    {:body (skill :body)
     :path (skill :path)
     :name (skill :name)
     :description (skill :description)
     :allowed-tools (skill :allowed-tools)}
    nil))

(defn count-skills
  "Return the number of discovered skills."
  []
  (length skills))

(defn system-prompt-snippet
  "Generate the system prompt section listing available skills."
  []
  (def skill-list (list-skills))
  (when (empty? skill-list)
    (break ""))
  (def lines @[""
               "## Available Skills"
               ""
               "The following skills provide specialized instructions for specific tasks."
               "Use the `use_skill` tool to activate a skill when the task matches its description."
               ""])
  (each s (sort-by |($ :name) skill-list)
    (array/push lines (string "- **" (s :name) "**: " (s :description))))
  (string/join lines "\n"))
