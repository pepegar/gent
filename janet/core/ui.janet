# UI module — terminal layout, colors, and rendering.
# Manages a two-region layout: scrollable output area + fixed 10-line bottom panel.
#
# ┌──────────────────────────────────┐
# │ output area (scroll region)      │ rows 1..(height-12)
# ╞══════════════════════════════════╡
# │ prompt (left)     │ panel (right)│ rows (height-10)..height
# │                   │              │
# │                   │              │
# └──────────────────────────────────┘
#
# The bottom panel is split vertically: left side is the input/prompt area,
# right side is a secondary panel (TBD). A vertical box-drawing character
# separates them.

# ── ANSI helpers ───────────────────────────────────────────────

(def- esc "\x1b")

(defn- csi [& parts]
  (string esc "[" ;(map string parts)))

(defn move-to [row col]
  (csi row ";" col "H"))

(defn set-scroll-region [top bottom]
  (csi top ";" bottom "r"))

(defn reset-scroll-region []
  (csi "r"))

(defn clear-line []
  (csi "2K"))

(defn clear-screen []
  (csi "2J"))

(defn save-cursor []
  (csi "s"))

(defn restore-cursor []
  (csi "u"))

# ── Color scheme ───────────────────────────────────────────────

(var- colors
  @{:user-label  (csi "1;38;5;39m")          # bold blue
    :agent-label (csi "1;38;5;214m")          # bold orange
    :agent-bg    (csi "48;5;235m")            # dark gray background
    :tool-label  (csi "1;38;5;78m")           # bold green
    :tool-bg     (csi "48;5;236m")            # slightly lighter gray
    :error-label (csi "1;38;5;196m")          # bold red
    :error-bg    (csi "48;5;52m")             # dark red background
    :separator   (csi "38;5;240m")            # dim gray
    :eval-bg     (csi "48;2;255;255;255m")    # white bg (tweak later)
    :eval-linenum (csi "38;2;140;140;160m")   # muted gray-blue for line numbers
    :eval-border (csi "38;2;180;180;190m")    # light gray for │
    :eval-code   (csi "38;2;30;30;30m")       # dark fg for code on white bg
    :reset       (csi "0m")})

(defn set-colors [overrides]
  (eachp [k v] overrides
    (put colors k v)))

(defn color [name]
  (get colors name ""))

# ── Layout state ───────────────────────────────────────────────

(var- layout @{:cols 80 :rows 24 :output-bottom 22 :separator-row 23 :input-row 24})

(defn refresh-layout []
  "Recalculate layout based on current terminal size."
  (def sz (term/size))
  (def cols (sz :cols))
  (def rows (sz :rows))
  (put layout :cols cols)
  (put layout :rows rows)
  (put layout :output-bottom (- rows 2))
  (put layout :separator-row (- rows 1))
  (put layout :input-row rows)
  layout)

(defn get-layout [] layout)

# ── Drawing helpers (defined before setup uses them) ───────────

(defn draw-separator []
  "Draw the separator line between output and input."
  (term/write (save-cursor))
  (term/write (move-to (layout :separator-row) 1))
  (term/write (clear-line))
  (term/write (color :separator))
  (term/write (string/repeat "─" (layout :cols)))
  (term/write (color :reset))
  (term/write (restore-cursor)))

(defn output [text]
  "Print text in the output scroll area, then return cursor to input."
  (term/write (save-cursor))
  # Move to bottom of scroll region so new text scrolls up
  (term/write (move-to (layout :output-bottom) 1))
  (term/write "\n")
  (term/write (clear-line))
  (term/write text)
  (term/write (color :reset))
  (term/write (restore-cursor)))

(defn output-lines [text]
  "Print multi-line text in the output area, one line at a time."
  (each line (string/split "\n" text)
    (output line)))

# ── Formatted output helpers ──────────────────────────────────

(def- indent-pad "       ")  # 7 chars to align with " gent  "

(defn output-user [text]
  (output (string (color :user-label) " you " (color :reset) " " text)))

(defn output-agent-start [text]
  "First line of an agent response — shows the label."
  (output (string (color :agent-label) " gent " (color :reset) " " text)))

(defn output-agent-cont [text]
  "Continuation line of an agent response — indented, no label."
  (output (string indent-pad text)))

(defn output-agent [lines]
  "Print a complete agent response. Takes a string (possibly multi-line)."
  (def parts (string/split "\n" lines))
  (var first true)
  (each line parts
    (when (not= "" line)
      (if first
        (do (output-agent-start line) (set first false))
        (output-agent-cont line)))))

(defn output-tool [name &opt detail]
  (def msg (if detail
             (string (color :tool-label) "  ▸ " name (color :reset) " " (color :separator) detail (color :reset))
             (string (color :tool-label) "  ▸ " name (color :reset))))
  (output msg))

(defn output-eval-janet [code]
  "Render eval_janet code with line numbers and subtle blue background."
  (def lines (string/split "\n" code))
  # Trim leading/trailing empty lines
  (var start 0)
  (var end (length lines))
  (while (and (< start end) (= "" (string/trim (get lines start ""))))
    (++ start))
  (while (and (> end start) (= "" (string/trim (get lines (- end 1) ""))))
    (-- end))
  # Header
  (output (string (color :tool-label) "  ▸ eval_janet" (color :reset)))
  (when (>= start end) (break))
  (def trimmed (array/slice lines start end))
  (def num-lines (length trimmed))
  (def num-width (max 2 (length (string num-lines))))
  (def cols (layout :cols))
  # Visual width of prefix: "    NN │ " = 4 + numwidth + 1 + 1 + 1
  (def prefix-vis (+ 7 num-width))
  (def code-avail (max 1 (- cols prefix-vis)))
  (def bg (color :eval-bg))
  (def ln (color :eval-linenum))
  (def bd (color :eval-border))
  (def cd (color :eval-code))
  (def rst (color :reset))
  (for i 0 num-lines
    (def linenum (string/format (string "%" num-width "d") (+ i 1)))
    (def code-line (get trimmed i ""))
    (def pad (max 0 (- code-avail (length code-line))))
    (output (string bg "    " ln linenum " " bd "│" cd bg " "
                    code-line (string/repeat " " pad) rst))))

(defn output-tool-result [text]
  "Render a tool call result. Shows each line dimmed and indented."
  (def lines (string/split "\n" text))
  (each line lines
    (output (string "    " (color :separator) line (color :reset)))))

(defn output-error [text]
  (output (string (color :error-label) " error " (color :reset) " " text)))

(defn output-info [text]
  (output (string (color :separator) text (color :reset))))

# ── Screen setup / teardown ────────────────────────────────────

(defn setup []
  "Initialize the TUI: raw mode, scroll region, draw separator."
  (refresh-layout)
  (term/enable-raw-mode)
  (term/write (clear-screen))
  (term/write (move-to 1 1))
  # Set scroll region to output area
  (term/write (set-scroll-region 1 (layout :output-bottom)))
  # Draw separator
  (draw-separator)
  # Position cursor at input row
  (term/write (move-to (layout :input-row) 1)))

(defn teardown []
  "Restore terminal to normal state."
  (term/write (reset-scroll-region))
  (term/write (move-to (layout :rows) 1))
  (term/write (string (color :reset) "\n"))
  (term/disable-raw-mode))
