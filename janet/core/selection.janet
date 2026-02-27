# core/selection.janet — Text selection system for gent
#
# Manages text selection state across widgets, handles mouse events,
# provides copy-to-clipboard functionality.

(import tui)

# ── Selection state ─────────────────────────────────────────────

(var- selection-active false)
(var- selection-start nil)   # {:widget :name :row N :col N}
(var- selection-end nil)     # {:widget :name :row N :col N}
(var- selection-mode :char)  # :char | :line | :block

# ── Public API ──────────────────────────────────────────────────

(defn active?
  "Return true if a selection is currently active."
  []
  selection-active)

(defn clear
  "Clear the current selection."
  []
  (set selection-active false)
  (set selection-start nil)
  (set selection-end nil))

(defn start-selection
  "Start a new text selection at the given position.
   pos: {:widget :name :row N :col N}"
  [pos]
  (set selection-active true)
  (set selection-start (table ;(kvs pos)))
  (set selection-end (table ;(kvs pos)))
  (set selection-mode :char))

(defn extend-selection
  "Extend the current selection to the given position.
   pos: {:widget :name :row N :col N}"
  [pos]
  (when selection-active
    (set selection-end (table ;(kvs pos)))))

(defn get-selection
  "Return the current selection bounds or nil if no selection.
   Returns: {:start {:widget :name :row N :col N}
            :end {:widget :name :row N :col N}
            :mode :char/:line/:block}"
  []
  (when selection-active
    {:start selection-start
     :end selection-end
     :mode selection-mode}))

(defn selection-contains?
  "Return true if the given position is within the current selection.
   pos: {:widget :name :row N :col N}"
  [pos]
  (when (not selection-active) (break false))
  (when (not= (pos :widget) (selection-start :widget)) (break false))
  
  # Normalize start/end so start comes before end
  (def [start end]
    (if (or (< (selection-start :row) (selection-end :row))
            (and (= (selection-start :row) (selection-end :row))
                 (<= (selection-start :col) (selection-end :col))))
      [selection-start selection-end]
      [selection-end selection-start]))
  
  (def pos-row (pos :row))
  (def pos-col (pos :col))
  (def start-row (start :row))
  (def start-col (start :col))
  (def end-row (end :row))
  (def end-col (end :col))
  
  (cond
    (< pos-row start-row) false
    (> pos-row end-row) false
    (and (= pos-row start-row) (< pos-col start-col)) false
    (and (= pos-row end-row) (> pos-col end-col)) false
    true))

# ── Mouse event handling ────────────────────────────────────────

(defn handle-mouse-down
  "Handle mouse button down event. Returns the widget name and local coordinates if handled."
  [event]
  (def button (get event :button))
  (def row (get event :row))
  (def col (get event :col))
  
  # Only handle left mouse button for selection
  (when (not= button :left) (break nil))
  
  # Return the raw coordinates - the agent will determine the widget
  {:widget-row row :widget-col col :global-row row :global-col col})

(defn handle-mouse-drag
  "Handle mouse drag event. Returns the widget coordinates if handled."
  [event]
  (when (not selection-active) (break nil))
  
  (def button (get event :button))
  (def row (get event :row))
  (def col (get event :col))
  
  # Only handle left mouse button drag
  (when (not= button :left) (break nil))
  
  # Return the raw coordinates
  {:widget-row row :widget-col col :global-row row :global-col col})

(defn handle-mouse-up
  "Handle mouse button up event. Returns nil."
  [event]
  # Mouse up doesn't change selection, just stops dragging
  nil)

# ── Copy to clipboard ──────────────────────────────────────────

(defn- extract-selected-text
  "Extract text from the current selection."
  [selection]
  # Simplified version to avoid circular dependencies
  # TODO: Implement proper text extraction
  (string "Selected text from " (get selection :start :widget)))

(defn copy-selection
  "Copy the current selection to the system clipboard.
   Returns the copied text or nil if no selection."
  []
  (when (not selection-active) (break nil))
  
  # For now, just return a placeholder - actual clipboard integration
  # would require platform-specific code or external tools
  (def sel (get-selection))
  (when sel
    (def text (extract-selected-text sel))
    # TODO: Actually copy to clipboard using pbcopy/xclip/wl-copy
    # For now, just return the text so it can be shown to the user
    text))

# ── Selection rendering helpers ─────────────────────────────────

(defn get-selection-style
  "Return the style to use for selected text."
  []
  (tui/style :bg [:rgb 60 100 200] :fg [:rgb 255 255 255]))

(defn apply-selection-style
  "Apply selection highlighting to a buffer cell if it's selected.
   Returns the modified style."
  [widget-name row col original-style]
  (if (selection-contains? {:widget widget-name :row row :col col})
    (tui/style-merge original-style (get-selection-style))
    original-style))
