# Custom color theme example
# Advanced theme customization for ~/.gent/init.janet

(import widgets/chat :as chat)
(import tui)  # Need to import tui for style function

# Start with dark theme
(chat/set-theme :dark)

# Create a custom "cyberpunk" color scheme
(chat/set-colors 
  @{# Neon colors for labels
    :user-label      (tui/style :fg [:rgb 0 255 255] :bold true)    # Cyan
    :agent-label     (tui/style :fg [:rgb 255 0 255] :bold true)   # Magenta
    :tool-label      (tui/style :fg [:rgb 0 255 0] :bold true)     # Green
    :error-label     (tui/style :fg [:rgb 255 100 100] :bold true) # Red
    :thinking-label  (tui/style :fg [:rgb 255 255 0] :italic true) # Yellow
    
    # Dark backgrounds with neon accents
    :user-row-bg     (tui/style :bg [:rgb 0 20 20])     # Dark cyan tint
    :agent-row-bg    (tui/style :bg [:rgb 20 0 20])     # Dark magenta tint
    :tool-row-bg     (tui/style :bg [:rgb 0 20 0])      # Dark green tint
    :tool-success-bg (tui/style :bg [:rgb 0 30 0])      # Brighter green
    :tool-error-bg   (tui/style :bg [:rgb 30 0 0])      # Dark red
    
    # Code display
    :eval-code       (tui/style :fg [:rgb 0 255 255] :bg [:rgb 10 10 30])
    :eval-linenum    (tui/style :fg [:rgb 100 100 255])
    :diff-green-fg   (tui/style :fg [:rgb 0 255 0] :bg [:rgb 0 30 0])
    :diff-red-fg     (tui/style :fg [:rgb 255 100 100] :bg [:rgb 30 0 0])
    
    # Markdown styling
    :md-h1           (tui/style :fg [:rgb 255 255 255] :bold true)
    :md-h2           (tui/style :fg [:rgb 0 255 255] :bold true)
    :md-code         (tui/style :fg [:rgb 0 255 0] :bg [:rgb 10 30 10])
    :md-link         (tui/style :fg [:rgb 100 100 255] :underline true)})

(print "Cyberpunk theme loaded!")