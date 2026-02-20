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

# ── Status provider ────────────────────────────────────────────
# A function that returns status text for the separator bar.
# Set by the agent or conversation module at startup.

(var- status-fn nil)

(defn set-status-provider
  "Set a function that returns status text for the separator bar.
   The function takes no arguments and returns a string (or nil)."
  [f]
  (set status-fn f))

# ── Drawing helpers (defined before setup uses them) ───────────

(defn draw-separator []
  "Draw the separator line between output and input.
   Shows session status info if a status provider is set."
  (term/write (save-cursor))
  (term/write (move-to (layout :separator-row) 1))
  (term/write (clear-line))
  (term/write (color :separator))
  (def status (when status-fn (try (status-fn) ([_] nil))))
  (if status
    (do
      (def status-text (string " " status " "))
      (def status-len (length status-text))
      (def left-dashes 2)
      (def right-dashes (max 0 (- (layout :cols) left-dashes status-len)))
      (term/write (string (string/repeat "─" left-dashes)
                          status-text
                          (string/repeat "─" right-dashes))))
    (term/write (string/repeat "─" (layout :cols))))
  (term/write (color :reset))
  (term/write (restore-cursor)))

(defn- visible-length
  "Return the visible length of a string, ignoring ANSI escape sequences."
  [s]
  (var len 0)
  (var in-esc false)
  (each byte s
    (if in-esc
      (when (and (>= byte 0x40) (<= byte 0x7E))
        (set in-esc false))
      (if (= byte 0x1B)
        (set in-esc true)
        (++ len))))
  len)

(defn output [text]
  "Print text in the output scroll area, then return cursor to input.
   Truncates to terminal width to prevent overflow into the prompt area."
  (def cols (layout :cols))
  (def vis-len (visible-length text))
  # If the visible text fits, write it as-is.
  # Otherwise hard-truncate to prevent overflow past the scroll region.
  (def safe-text
    (if (<= vis-len cols)
      text
      (do
        (var vis 0)
        (var in-esc false)
        (var cut-at (length text))
        (for i 0 (length text)
          (def byte (get text i))
          (if in-esc
            (when (and (>= byte 0x40) (<= byte 0x7E))
              (set in-esc false))
            (if (= byte 0x1B)
              (set in-esc true)
              (do
                (++ vis)
                (when (>= vis cols)
                  (set cut-at (+ i 1))
                  (break))))))
        (string (string/slice text 0 cut-at) (color :reset)))))
  (term/write (save-cursor))
  # Move to bottom of scroll region so new text scrolls up
  (term/write (move-to (layout :output-bottom) 1))
  (term/write "\n")
  (term/write (clear-line))
  (term/write safe-text)
  (term/write (color :reset))
  (term/write (restore-cursor)))

(defn output-lines [text]
  "Print multi-line text in the output area, one line at a time."
  (each line (string/split "\n" text)
    (output line)))

# ── Line wrapping ──────────────────────────────────────────────

(defn- wrap-line [text max-width]
  "Word-wrap a plain text line to max-width. Returns an array of lines.
   Breaks at the last space before max-width when possible, otherwise hard-breaks."
  (if (<= (length text) max-width)
    @[text]
    (do
      (def result @[])
      (var start 0)
      (while (< start (length text))
        (def remaining (- (length text) start))
        (if (<= remaining max-width)
          (do
            (array/push result (string/slice text start))
            (set start (length text)))
          (do
            (def chunk-end (+ start max-width))
            # Look for a space to break at (scan backward from chunk-end)
            (var break-at nil)
            (for i 0 max-width
              (def pos (- chunk-end 1 i))
              (when (= (get text pos) (chr " "))
                (set break-at pos)
                (break)))
            (if (and break-at (> break-at start))
              (do
                (array/push result (string/slice text start break-at))
                (set start (+ break-at 1)))  # skip the space
              (do
                # No space found — hard break
                (array/push result (string/slice text start chunk-end))
                (set start chunk-end))))))
      result)))

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
  "Print a complete agent response. Takes a string (possibly multi-line).
   Word-wraps lines that exceed terminal width."
  (def parts (string/split "\n" lines))
  (def max-width (max 20 (- (layout :cols) 8)))  # 7 indent + 1 margin
  (var first true)
  (each line parts
    (if (= "" line)
      (output "")  # preserve blank lines
      (do
        (def wrapped (wrap-line line max-width))
        (each wl wrapped
          (if first
            (do (output-agent-start wl) (set first false))
            (output-agent-cont wl)))))))

# ── Streaming output state ─────────────────────────────────────

(var- stream-state @{:active false :line-buf @"" :first true})

(defn stream-start []
  "Begin a streaming agent response. Must call stream-end when done."
  (put stream-state :active true)
  (put stream-state :first true)
  (buffer/clear (stream-state :line-buf)))

(defn stream-delta [text]
  "Append a text delta to the streaming output. Handles line wrapping and newlines."
  (def buf (stream-state :line-buf))
  (def max-width (max 20 (- (layout :cols) 8)))

  (each byte text
    (if (= byte (chr "\n"))
      (do
        # Flush current line
        (def line (string buf))
        (buffer/clear buf)
        (if (= "" line)
          (output "")
          (do
            (def wrapped (wrap-line line max-width))
            (each wl wrapped
              (if (stream-state :first)
                (do (output-agent-start wl) (put stream-state :first false))
                (output-agent-cont wl))))))
      (buffer/push buf byte))))

(defn stream-end []
  "Finish a streaming agent response. Flushes any remaining text."
  (def buf (stream-state :line-buf))
  (def max-width (max 20 (- (layout :cols) 8)))
  (when (> (length buf) 0)
    (def line (string buf))
    (def wrapped (wrap-line line max-width))
    (each wl wrapped
      (if (stream-state :first)
        (do (output-agent-start wl) (put stream-state :first false))
        (output-agent-cont wl))))
  (buffer/clear buf)
  (put stream-state :active false)
  (put stream-state :first true))

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

(defn output-edit-file [input]
  "Render edit_file tool call with a diff-like display showing path, removed, and added lines."
  (def path (get input :path ""))
  (def old-str (get input :old_str ""))
  (def new-str (get input :new_str ""))
  (def cols (layout :cols))
  (def rst (color :reset))
  (def sep (color :separator))

  # Header: tool name + file path
  (def is-create (= "" old-str))
  (if is-create
    (output (string (color :tool-label) "  ▸ edit_file" rst " " sep path rst
                    " " (color :tool-label) "(new file)" rst))
    (output (string (color :tool-label) "  ▸ edit_file" rst " " sep path rst)))

  # Colors for diff lines
  (def red-bg (csi "48;5;52m"))      # dark red background for removed
  (def red-fg (csi "38;5;210m"))     # light red text for removed
  (def green-bg (csi "48;5;22m"))    # dark green background for added
  (def green-fg (csi "38;5;114m"))   # light green text for added
  (def line-max (max 20 (- cols 10)))
  (def max-diff-lines 8)

  # Show removed lines (old_str)
  (when (not= "" old-str)
    (def old-lines (string/split "\n" old-str))
    (def show-n (min (length old-lines) max-diff-lines))
    (for i 0 show-n
      (def line (get old-lines i ""))
      (def truncated (if (> (length line) line-max)
                       (string (string/slice line 0 (- line-max 1)) "…")
                       line))
      (def pad (max 0 (- line-max (length truncated))))
      (output (string red-bg "    " red-fg "- " truncated (string/repeat " " pad) rst)))
    (when (> (length old-lines) max-diff-lines)
      (output (string "    " sep "  … " (- (length old-lines) max-diff-lines) " more lines" rst))))

  # Show added lines (new_str)
  (when (not= "" new-str)
    (def new-lines (string/split "\n" new-str))
    (def show-n (min (length new-lines) max-diff-lines))
    (for i 0 show-n
      (def line (get new-lines i ""))
      (def truncated (if (> (length line) line-max)
                       (string (string/slice line 0 (- line-max 1)) "…")
                       line))
      (def pad (max 0 (- line-max (length truncated))))
      (output (string green-bg "    " green-fg "+ " truncated (string/repeat " " pad) rst)))
    (when (> (length new-lines) max-diff-lines)
      (output (string "    " sep "  … " (- (length new-lines) max-diff-lines) " more lines" rst)))))

(var- tool-result-max-lines 10)

(defn set-tool-result-max-lines [n]
  "Override the maximum number of lines shown for tool results."
  (set tool-result-max-lines n))

(defn- truncate-line [line max-width]
  "Truncate a line to max-width characters, adding … if truncated."
  (if (<= (length line) max-width)
    line
    (string (string/slice line 0 (- max-width 1)) "…")))

(defn output-tool-result [text]
  "Render a tool call result. Shows each line dimmed and indented.
   Truncates to tool-result-max-lines lines and max line width of cols - 10."
  (def lines (string/split "\n" text))
  (def total (length lines))
  (def max-width (max 20 (- (layout :cols) 10)))
  (def show-lines (min total tool-result-max-lines))
  (for i 0 show-lines
    (def line (truncate-line (get lines i "") max-width))
    (output (string "    " (color :separator) line (color :reset))))
  (when (> total tool-result-max-lines)
    (def omitted (- total tool-result-max-lines))
    (output (string "    " (color :separator) "… " omitted " more lines omitted" (color :reset)))))

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

(defn restore []
  "Restore TUI after resuming from suspend (ctrl-z).
   Re-enables raw mode is already done by term/suspend, so just redraw."
  (refresh-layout)
  (term/write (clear-screen))
  (term/write (move-to 1 1))
  (term/write (set-scroll-region 1 (layout :output-bottom)))
  (draw-separator)
  (output-info "resumed — gent")
  (term/write (move-to (layout :input-row) 1)))
