# gent — the extensible coding agent
# This is the entry point. Like Emacs's loadup.el.
# Rust inits the VM, registers native functions, and runs this file.
# From here on, Janet owns everything.

# Core modules
(import core/tools :as tools)
(import core/api :as api)
(import core/ui :as ui)
(import core/editor :as editor)
(import core/agent :as agent)
(import core/skills :as skills)
(import core/agents-md :as agents-md)
(import core/buffers :as buffers)

# Built-in tools
(import tools/read-file)
(import tools/list-files)
(import tools/edit-file)
(import tools/bash)
(import tools/eval-janet)
(import tools/use-skill)

# Discover skills from .gent/skills/ and .agents/skills/
(skills/init-paths)
(skills/discover)

# Discover AGENTS.md files walking up from cwd
(agents-md/discover)

# User config (like .emacs — override anything here)
(try
  (import init)
  ([_] nil))

# Start the agent
(agent/run)
