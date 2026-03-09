# test/run.janet — Test runner for gent.
#
# Usage (from project root): janet janet/test/run.janet

# Set sessions directory to a temp location to avoid polluting ~/.gent/sessions
(os/setenv "GENT_SESSIONS_DIR" "/tmp/gent-test-sessions")

# Find the janet/ directory
(def janet-dir
  (if (os/stat "janet/core") "janet"
    (if (os/stat "core") "." nil)))
(unless janet-dir
  (eprint "Run from the project root or janet/ directory")
  (os/exit 1))

# Add janet/ to module search paths so imports work
(each suffix [".janet" "/init.janet"]
  (array/push module/paths [(string janet-dir "/:all:" suffix) :source]))

(def- test-files
  ["test/test-rect"
   "test/test-style"
   "test/test-buffer"
   "test/test-text"
   "test/test-block"
   "test/test-layout"
   "test/test-declarative-layout"
   "test/test-hooks"
   "test/test-commands"
   "test/test-registers"
   "test/test-abort"
   "test/test-buffers"
   "test/test-widget"
   "test/test-chat"
   "test/test-chat-integration"
   "test/test-completion"
   "test/test-input-history"
   "test/test-inspect"
   "test/test-snapshot"
   "test/test-profile"
   "test/test-stage"
   "test/test-scenario"
   "test/test-thinking"
   "test/test-spinner"
   "test/test-editor-scroll"
   "test/test-charwidth"
   "test/test-dialog"
   "test/test-rpc"
   "test/test-headless"
   "test/test-truncate"
   "test/test-markdown"
   "test/test-focus-grid"
   "test/test-filepicker"
   "test/test-fuzzy"
   "test/test-model"
   "test/test-bash-progress"
   "test/test-bash-progress-integration"
   "test/test-ansi"])

# Install native function mocks (http, json, term, process) so that
# tests importing widgets/chat and other modules that use native
# functions can run under plain `janet` without the Rust runtime.
# Mocks must be in the root environment so module compilation finds them.
(import test/fake-http :as fake)
(fake/install (curenv))
# Also install into the root env (prototype chain) so that modules
# loaded via import/require see the mocks during compilation.
(var env (curenv))
(while (table/getproto env)
  (set env (table/getproto env)))
(fake/install env)

(import test/helper :as t)

(var- total-tests 0)
(var- total-fail 0)
(var- total-error 0)

(each mod test-files
  (def path (string janet-dir "/" mod ".janet"))
  (try
    (do
      (t/reset)
      (dofile path)
      (+= total-tests (t/tests))
      (+= total-fail (t/fail)))
    ([err]
     (eprintf "ERROR loading %s: %s" mod (string err))
     (++ total-error))))

(print)
(printf "═══ Results: %d tests, %d failed, %d errors ═══"
        total-tests total-fail total-error)
(when (or (> total-fail 0) (> total-error 0))
  (os/exit 1))
