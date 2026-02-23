# gent — the extensible coding agent
# This is the entry point. Like Emacs's loadup.el.
# Rust inits the VM, registers native functions, and runs this file.
# From here on, Janet owns everything.

# Core modules
(import core/tools :as tools)
(import core/api :as api)
(import core/ui :as ui)
(import core/editor :as editor)
(import core/widget :as widget)
(import core/agent :as agent)
(import core/skills :as skills)
(import core/agents-md :as agents-md)
(import core/buffers :as buffers)
(import core/conversation :as conv)
(import core/commands :as commands)
(import core/registers :as reg)

# Built-in tools
(import tools/read-file)
(import tools/list-files)
(import tools/edit-file)
(import tools/bash)
(import tools/eval-janet)
(import tools/use-skill)

# Built-in slash commands
(import commands/conversation)
(import commands/auth)
(import commands/introspection)

# Discover skills from .gent/skills/ and .agents/skills/
(skills/init-paths)
(skills/discover)

# Discover AGENTS.md files walking up from cwd
(agents-md/discover)

# User config — load ~/.gent/init.janet if it exists (like ~/.emacs)
# We add ~/.gent/ to the module path so user init can (import) their own modules from there too.
(def- loaded-configs @[])

(def- gent-home (let [home (os/getenv "HOME")]
                  (when home (string home "/.gent"))))
(when gent-home
  # Add ~/.gent/ to module search paths so user init can (import) their own modules.
  # Janet's :syspath is a single directory (substituted for :sys: in module/paths),
  # NOT a colon/semicolon-separated list. We add ~/.gent as additional search entries.
  (each suffix [".janet" "/init.janet"]
    (array/push module/paths [(string gent-home "/:all:" suffix) :source]))
  (each suffix [".jimage" ".so"]
    (array/push module/paths [(string gent-home "/:all:" suffix) :native]))
  (def user-init-path (string gent-home "/init.janet"))
  (when (os/stat user-init-path)
    (try
      (do
        (dofile user-init-path)
        (array/push loaded-configs user-init-path))
      ([err]
        (eprintf "Error loading %s: %s" user-init-path (string err))))))

# Project config — load .gent/init.janet from cwd if it exists (like .dir-locals.el)
(def- project-init-path ".gent/init.janet")
(when (os/stat project-init-path)
  (try
    (do
      (dofile project-init-path)
      (array/push loaded-configs project-init-path))
    ([err]
      (eprintf "Error loading %s: %s" project-init-path (string err)))))

# Stash loaded config paths for the startup banner
(reg/set :loaded-configs loaded-configs)

# Start the agent
(agent/run)
