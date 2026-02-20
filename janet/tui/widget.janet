# tui/widget.janet — Widget protocol.
#
# A widget is any table with a :render key that is a function:
#   (fn [self rect buf] ...)
#
# The `render` function dispatches to the widget's render method.
# Strings are automatically treated as plain text widgets.

(use ./rect)
(use ./buffer)
(use ./style)

(defn render
  "Render a widget into a buffer within the given rect.
   Widgets are tables/structs with a :render function.
   Strings are rendered as plain text."
  [widget area buf]
  (when (rect-empty? area) (break))
  (cond
    (string? widget)
    (buffer-set-string buf (area :x) (area :y) widget)

    (function? (get widget :render))
    ((widget :render) widget area buf)

    (errorf "cannot render %q — not a widget (missing :render method)" widget)))
