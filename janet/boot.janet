# gent — the extensible coding agent
# This is the entry point. Like Emacs's loadup.el.
# Rust inits the VM, registers native functions, and runs this file.
# From here on, Janet owns everything.

# Core modules
(import core/tools :as tools)
(import core/api :as api)
(import core/ui :as ui)
(import core/widget :as widget)
(import core/agent :as agent)
(import core/skills :as skills)
(import core/agents-md :as agents-md)
(import core/buffers :as buffers)
(import core/conversation :as conv)
(import core/commands :as commands)
(import core/registers :as reg)
(import core/profile :as profile)

# Built-in tools
(import tools/read-file)
(import tools/list-files)
(import tools/edit-file)
(import tools/bash)
(import tools/eval-janet)
(import tools/use-skill)
(import tools/prompt-user)

# Built-in slash commands
(import commands/conversation)
(import commands/auth)
(import commands/introspection)
(import commands/profile)
(import commands/model)
(import commands/provider)

# Discover skills from .gent/skills/ and .agents/skills/
(skills/init-paths)
(skills/discover)

# Discover AGENTS.md files walking up from cwd
(agents-md/discover)

# Auto-detect OS dark/light mode and apply matching Catppuccin theme.
# User can override in ~/.gent/init.janet with (chat/set-theme :dark) etc.
(import widgets/chat :as chat)
(chat/auto-theme)

# User config — load ~/.gent/init.janet if it exists (like ~/.emacs)
# We add ~/.gent/ to the module path so user init can (import) their own modules from there too.
# Skipped when -q / --no-init-file is passed (sets :gent/no-init dynamic var).
(def- loaded-configs @[])

(def- gent-home (let [home (os/getenv "HOME")]
                  (when home (string home "/.gent"))))
(when gent-home
  # Always add ~/.gent/ to module search paths (even with -q) so -l files can import from there.
  (each suffix [".janet" "/init.janet"]
    (array/push module/paths [(string gent-home "/:all:" suffix) :source]))
  (each suffix [".jimage" ".so"]
    (array/push module/paths [(string gent-home "/:all:" suffix) :native]))
  (unless (dyn :gent/no-init)
    (def user-init-path (string gent-home "/init.janet"))
    (when (os/stat user-init-path)
      (try
        (do
          (dofile user-init-path)
          (array/push loaded-configs user-init-path))
        ([err]
         (eprintf "Error loading %s: %s" user-init-path (string err)))))))

# Project config — load .gent/init.janet from cwd if it exists (like .dir-locals.el)
(unless (dyn :gent/no-init)
  (def- project-init-path ".gent/init.janet")
  (when (os/stat project-init-path)
    (try
      (do
        (dofile project-init-path)
        (array/push loaded-configs project-init-path))
      ([err]
       (eprintf "Error loading %s: %s" project-init-path (string err))))))

# Load files specified via -l / --load
(when-let [load-files (dyn :gent/load-files)]
  (each f load-files
    (try
      (do (dofile f)
          (array/push loaded-configs f))
      ([err]
       (eprintf "Error loading %s: %s" f (string err))))))

# Stash loaded config paths for the startup banner
(reg/set :loaded-configs loaded-configs)

# Start the agent — headless, stage, or interactive (with optional RPC)
(def- rpc-port (dyn :gent/port))

(import core/stage :as stage)
(import core/headless :as headless)

(if (dyn :gent/headless)
  (headless/run (or rpc-port 7888))
  (do
    (def stage-script (os/getenv "GENT_STAGE"))
    (if stage-script
      (do
        (stage/install)
        (when (and (not= stage-script "1") (os/stat stage-script))
          (dofile stage-script))
        (agent/run rpc-port))
      (agent/run rpc-port))))
