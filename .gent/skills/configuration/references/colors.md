# Color Customization

Complete guide to customizing gent's color scheme.

## Available Color Keys

The color scheme supports these keys:

```janet
# Labels and text
:user-label      # "user:" label
:agent-label     # "gent:" label
:tool-label      # "▸ tool_name" labels
:error-label     # "err:" label
:thinking-label  # "think:" label
:separator       # General dim text
:reset          # Reset to default

# Backgrounds for message rows
:user-row-bg     # User message background
:agent-row-bg    # Agent message background
:thinking-row-bg # Thinking content background
:tool-row-bg     # Tool call background
:tool-success-bg # Successful tool result
:tool-error-bg   # Failed tool result

# Code display
:eval-linenum    # Line numbers in code blocks
:eval-border     # Border characters (│)
:eval-code       # Code text and background
:diff-red-fg     # Removed lines in edit_file
:diff-green-fg   # Added lines in edit_file

# Command-specific
:bash-exit-fail  # Failed exit status
:bash-prompt     # Bash prompt ($)

# Markdown (for agent responses)
:md-h1 to :md-h6 # Headers
:md-code         # Inline code
:md-code-block   # Code blocks
:md-link         # Links
:md-list-marker  # List bullets/numbers
```

## Color Syntax

Colors are specified using `tui/style` with these options:

```janet
# RGB colors
(tui/style :fg [:rgb 255 128 0] :bg [:rgb 40 40 40])

# Named colors
(tui/style :fg :red :bg :black)

# 256-color palette (0-255)
(tui/style :fg [:idx 214] :bg [:idx 235])

# Style modifiers
(tui/style :fg :blue :bold true :italic true :underline true)
```

## Custom Color Schemes

Override individual colors while keeping the rest of a theme:

```janet
(import widgets/chat :as chat)

# Start with dark theme
(chat/set-theme :dark)

# Override specific colors
(chat/set-colors
  @{:user-label    (tui/style :fg [:rgb 255 100 100] :bold true)  # Custom red
    :agent-label   (tui/style :fg [:rgb 100 255 100] :bold true) # Custom green
    :tool-label    (tui/style :fg [:rgb 100 100 255] :bold true) # Custom blue
    :separator     (tui/style :fg [:rgb 128 128 128])            # Custom gray
    :eval-code     (tui/style :fg [:rgb 200 200 200] :bg [:rgb 40 40 40])})
```

## Built-in Themes

Gent has two built-in Catppuccin themes:

```janet
# Switch to dark theme (Catppuccin Mocha)
(import widgets/chat :as chat)
(chat/set-theme :dark)

# Switch to light theme (Catppuccin Latte)
(chat/set-theme :light)

# Auto-detect OS dark/light mode (default behavior)
(chat/auto-theme)
```
