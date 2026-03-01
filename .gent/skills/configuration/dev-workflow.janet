# Development workflow configuration
# Project-specific config example for .gent/init.janet

(import core/hooks :as hooks)
(import core/tools :as tools)
(import core/commands :as commands)

# Auto-format code files after editing
(hooks/add :after-tool-call
  (fn [name input result]
    (when (= name "edit_file")
      (def path (get input :path ""))
      (cond
        # Format Rust files with rustfmt
        (string/has-suffix? ".rs" path)
        (process/exec "rustfmt" [path])
        
        # Format Python files with black  
        (string/has-suffix? ".py" path)
        (process/exec "black" [path])
        
        # Format JavaScript/TypeScript with prettier
        (or (string/has-suffix? ".js" path)
            (string/has-suffix? ".ts" path)
            (string/has-suffix? ".jsx" path)
            (string/has-suffix? ".tsx" path))
        (process/exec "prettier" ["--write" path])
        
        # Format Janet files with parinfer
        (string/has-suffix? ".janet" path)
        (process/exec "parinfer-rust" ["-m" "paren" "-l" "janet" "-i" path])))))

# Custom development tools
(tools/register "test"
  {:description "Run project tests"
   :schema {:type "object"
            :properties {:path {:type "string" :description "Test file or directory"}}
            :required []}
   :function (fn [input]
               (def path (get input :path "."))
               (cond
                 # Detect test framework and run appropriate command
                 (os/stat "Cargo.toml")
                 (let [result (process/exec "cargo" ["test"])]
                   (result :stdout))
                 
                 (os/stat "package.json") 
                 (let [result (process/exec "npm" ["test"])]
                   (result :stdout))
                 
                 (os/stat "pytest.ini")
                 (let [result (process/exec "pytest" ["-v" path])]
                   (result :stdout))
                 
                 "No test framework detected"))})

(tools/register "lint"
  {:description "Run linters on the project"
   :schema {:type "object" :properties {} :required []}
   :function (fn [input]
               (def results @[])
               (cond
                 (os/stat "Cargo.toml")
                 (array/push results ((process/exec "cargo" ["clippy"]) :stdout))
                 
                 (os/stat ".eslintrc")
                 (array/push results ((process/exec "eslint" ["."]) :stdout)))
               (string/join results "\n\n"))})

# Git workflow commands
(commands/register "status"
  {:description "Show git status"
   :usage "/status"
   :function (fn [args]
               (def result (process/exec "git" ["status" "--porcelain"]))
               (if (= 0 (result :status))
                 (if (= "" (string/trim (result :stdout)))
                   "Working tree clean"
                   (result :stdout))
                 (result :stderr)))})

(commands/register "diff"
  {:description "Show git diff"
   :usage "/diff [file]"
   :function (fn [args]
               (def cmd-args (if (= "" (string/trim args))
                              ["diff"]
                              ["diff" (string/trim args)]))
               (def result (process/exec "git" cmd-args))
               (result :stdout))})

# Prevent editing certain files
(hooks/add :before-tool-call
  (fn [name input]
    (when (= name "edit_file")
      (def path (get input :path ""))
      (def restricted ["node_modules/" "target/" "build/" ".git/" "vendor/"])
      (def restricted? (some |(string/has-prefix? $ path) restricted))
      (when restricted?
        (error (string "Refusing to edit restricted path: " path))))))

(print "Development workflow configuration loaded!")