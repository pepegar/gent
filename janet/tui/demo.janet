# tui/demo.janet — Visual demo of the TUI library.
#
# Run:  cd janet && JANET_PATH="$(pwd):$JANET_PATH" janet tui/demo.janet

(use ./init)

# ── Screen area ────────────────────────────────────────────────

(def area (rect 0 0 56 18))
(def buf (buffer area))

# ── Outer frame ────────────────────────────────────────────────

(def outer
  (block :title "My TUI App"
         :borders :all
         :border-type :rounded
         :border-style (style :fg :cyan)
         :padding (padding 1 1 1 1)))

(render outer area buf)
(def outer-inner (block-inner outer area))

# ── Split: panels on top, footer at bottom ─────────────────────

(def [panels-area footer-area] (vsplit outer-inner :fill 1))

# ── Split panels: left + gap + right ──────────────────────────

(def [left-area _ right-area] (hsplit panels-area 26 2 :fill))

# ── Left: Messages ─────────────────────────────────────────────

(def msg-block
  (block :title "Messages"
         :borders :all
         :border-type :plain
         :border-style (style :fg :white)
         :padding (padding 1 0 0 0)))

(render msg-block left-area buf)
(def msg-inner (block-inner msg-block left-area))

(render
  (text
    (line (span "Hello, World!" (style :fg :green :bold true)))
    (line (span "Welcome to" (style :fg :white)))
    (line (span "the Janet TUI" (style :fg :yellow :italic true)))
    (line (span ""))
    (line (span "It's composable!" (style :fg :magenta))))
  msg-inner buf)

# ── Right: Status ──────────────────────────────────────────────

(def status-block
  (block :title "Status"
         :borders :all
         :border-type :plain
         :border-style (style :fg :white)
         :padding (padding 1 0 0 0)))

(render status-block right-area buf)
(def status-inner (block-inner status-block right-area))

(render
  (text
    (line (span "● " (style :fg :green :bold true))
          (span "Connected" (style :fg :white)))
    (line (span ""))
    (line (span "Uptime: " (style :fg :bright-black))
          (span "42s" (style :fg :yellow)))
    (line (span ""))
    (line (span "CPU: " (style :fg :bright-black))
          (span "12%" (style :fg :cyan))))
  status-inner buf)

# ── Footer ─────────────────────────────────────────────────────

(render
  (text (line (span "Press " (style :fg :bright-black))
              (span "q" (style :fg :white :bold true))
              (span " to quit" (style :fg :bright-black))))
  footer-area buf)

# ── Output ─────────────────────────────────────────────────────

(prin (buffer->str buf))
(print)
