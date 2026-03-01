# Advanced Configuration

## Data Storage with Registers

Use registers for persistent data across sessions:

```janet
(import core/registers :as reg)

# Store data
(reg/set :my-config @{:theme "dark" :font-size 14})

# Read data
(def config (reg/get :my-config @{}))  # Default to empty table

# Update data
(def config (reg/get :my-config @{}))
(put config :theme "light")
(reg/set :my-config config)
```

## API Configuration

Modify API settings:

```janet
(import core/api :as api)

# Override model
(api/set-config {:model "claude-3-5-haiku-20241022"})

# Multiple settings
(api/set-config {:model "gpt-4o"
                 :max-tokens 8192
                 :url "https://api.openai.com/v1"})
```

## Conditional Configuration

Load different settings based on environment:

```janet
# Different settings for work vs personal
(def hostname (string/trim ((process/exec "hostname" []) :stdout)))

(cond
  (string/has-prefix? "work-" hostname)
  (do
    (import widgets/chat :as chat)
    (chat/set-theme :light)
    (import core/api :as api)
    (api/set-config {:model "claude-3-5-sonnet-20241022"}))

  (= hostname "personal-laptop")
  (do
    (import widgets/chat :as chat)
    (chat/set-theme :dark)
    (import core/api :as api)
    (api/set-config {:model "gpt-4o"})))
```

## Project-Specific Configuration

Create `.gent/init.janet` in a project directory:

```janet
# .gent/init.janet in a Python project
(import core/hooks :as hooks)
(import core/tools :as tools)

# Auto-format Python files
(hooks/add :after-tool-call
  (fn [name input result]
    (when (and (= name "edit_file")
               (string/has-suffix? ".py" (get input :path "")))
      # Auto-format with black
      (process/exec "black" [(get input :path "")]))))

# Custom Python tool
(tools/register "pytest"
  {:description "Run pytest on a file or directory"
   :schema {:type "object"
            :properties {:path {:type "string" :description "Path to test"}}
            :required ["path"]}
   :function (fn [input]
               (def result (process/exec "pytest" ["-v" (get input :path ".")]))
               (result :stdout))})
```

## Module System

Configuration files can import additional modules from `~/.gent/`:

```janet
# ~/.gent/my-tools.janet
(import core/tools :as tools)

(defn register-my-tools []
  (tools/register "example"
    {:description "Example tool"
     :schema {:type "object" :properties {} :required []}
     :function (fn [input] "Hello from my tool!")}))
```

```janet
# ~/.gent/init.janet
(import my-tools)
(my-tools/register-my-tools)
```

The `~/.gent/` directory is automatically added to Janet's module path.

## Widget Discovery and Loading

Widgets can be auto-loaded from directories:

```bash
# Create widget directories
mkdir -p ~/.gent/widgets      # User widgets
mkdir -p .gent/widgets        # Project widgets
```

Place widget files in these directories:

```janet
# ~/.gent/widgets/my-widget.janet
(import core/widget :as widget)

(defn create []
  @{:name :my-widget
    # ... widget definition
    })

# Auto-register when loaded
(widget/register (create))
```

Enable auto-discovery in your config:

```janet
# ~/.gent/init.janet
(import core/widget :as widget)
(def loaded (widget/discover-widgets))
(printf "Loaded %d custom widgets" (length loaded))
```

## Debugging Configuration

If your config has errors, they'll be shown at startup. You can also:

```janet
# Check what configs were loaded
(import core/registers :as reg)
(def loaded (reg/get :loaded-configs))
(each path loaded (printf "Loaded: %s" path))

# Test Janet code interactively
# Use eval_janet tool to test config code before putting it in init.janet
```
