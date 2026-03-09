# tui/ansi.janet — Parse ANSI escape codes in text into styled spans.
#
# Converts strings containing ANSI SGR escape sequences (e.g. "\x1b[35m")
# into arrays of {:text :style} spans suitable for push-raw-line.
#
# Supported: SGR codes (colors, bold, italic, dim, underline, reverse, reset).
# Unsupported sequences are silently stripped.

(use ./style)

(defn- parse-sgr-codes
  "Parse semicolon-separated SGR parameter codes and return a style struct.
   Applies codes cumulatively to the given base style."
  [codes base-style]
  (def entries @{})
  # Copy base style (skip :_sgr)
  (when base-style
    (eachp [k v] base-style
      (when (not= k :_sgr)
        (put entries k v))))
  (var i 0)
  (while (< i (length codes))
    (def code (get codes i))
    (cond
      # Reset
      (= code 0)
      (do
        (eachp [k _] entries (put entries k nil))
        (++ i))

      # Bold
      (= code 1) (do (put entries :bold true) (++ i))
      # Dim
      (= code 2) (do (put entries :dim true) (++ i))
      # Italic
      (= code 3) (do (put entries :italic true) (++ i))
      # Underline
      (= code 4) (do (put entries :underline true) (++ i))
      # Reverse
      (= code 7) (do (put entries :reversed true) (++ i))

      # Bold off
      (= code 22) (do (put entries :bold nil) (put entries :dim nil) (++ i))
      # Italic off
      (= code 23) (do (put entries :italic nil) (++ i))
      # Underline off
      (= code 24) (do (put entries :underline nil) (++ i))
      # Reverse off
      (= code 27) (do (put entries :reversed nil) (++ i))

      # Standard foreground colors 30-37
      (and (>= code 30) (<= code 37))
      (do
        (def color-names [:black :red :green :yellow :blue :magenta :cyan :white])
        (put entries :fg (get color-names (- code 30)))
        (++ i))

      # Default foreground
      (= code 39) (do (put entries :fg nil) (++ i))

      # Standard background colors 40-47
      (and (>= code 40) (<= code 47))
      (do
        (def color-names [:black :red :green :yellow :blue :magenta :cyan :white])
        (put entries :bg (get color-names (- code 40)))
        (++ i))

      # Default background
      (= code 49) (do (put entries :bg nil) (++ i))

      # Bright foreground colors 90-97
      (and (>= code 90) (<= code 97))
      (do
        (def color-names [:bright-black :bright-red :bright-green :bright-yellow
                          :bright-blue :bright-magenta :bright-cyan :bright-white])
        (put entries :fg (get color-names (- code 90)))
        (++ i))

      # Bright background colors 100-107
      (and (>= code 100) (<= code 107))
      (do
        (def color-names [:bright-black :bright-red :bright-green :bright-yellow
                          :bright-blue :bright-magenta :bright-cyan :bright-white])
        (put entries :bg (get color-names (- code 100)))
        (++ i))

      # 256-color: 38;5;N (fg) or 48;5;N (bg)
      (and (or (= code 38) (= code 48))
           (< (+ i 2) (length codes))
           (= (get codes (+ i 1)) 5))
      (do
        (def n (get codes (+ i 2)))
        (if (= code 38)
          (put entries :fg [:indexed n])
          (put entries :bg [:indexed n]))
        (+= i 3))

      # 24-bit color: 38;2;R;G;B (fg) or 48;2;R;G;B (bg)
      (and (or (= code 38) (= code 48))
           (< (+ i 4) (length codes))
           (= (get codes (+ i 1)) 2))
      (do
        (def r (get codes (+ i 2)))
        (def g (get codes (+ i 3)))
        (def b (get codes (+ i 4)))
        (if (= code 38)
          (put entries :fg [:rgb r g b])
          (put entries :bg [:rgb r g b]))
        (+= i 5))

      # Unknown code — skip
      (++ i)))

  # Build style from entries (filter out nils)
  (def style-args @[])
  (eachp [k v] entries
    (when (not (nil? v))
      (array/push style-args k)
      (array/push style-args v)))
  (if (empty? style-args)
    style-default
    (style ;style-args)))

(defn ansi->spans
  "Parse a string with ANSI escape codes into an array of {:text :style} spans.
   The optional base-style is applied as the default style for unstyled text."
  [text &opt base-style]
  (default base-style style-default)
  (def spans @[])
  (var current-style base-style)
  (def buf @"")
  (var i 0)

  (defn flush-buf []
    (when (> (length buf) 0)
      (array/push spans @{:text (string buf) :style current-style})
      (buffer/clear buf)))

  (while (< i (length text))
    (def byte (get text i))
    (if (= byte 0x1b)
      (do
        # Check for CSI sequence: ESC [
        (if (and (< (+ i 1) (length text)) (= (get text (+ i 1)) (chr "[")))
          (do
            (flush-buf)
            # Parse the CSI parameters
            (var j (+ i 2))
            (def param-buf @"")
            (while (and (< j (length text))
                        (or (and (>= (get text j) (chr "0")) (<= (get text j) (chr "9")))
                            (= (get text j) (chr ";"))))
              (buffer/push param-buf (get text j))
              (++ j))
            # j now points to the final character of the sequence
            (if (< j (length text))
              (do
                (def final-char (get text j))
                (if (= final-char (chr "m"))
                  (do
                    # SGR sequence — parse the codes
                    (def param-str (string param-buf))
                    (def codes
                      (if (= "" param-str)
                        @[0]  # ESC[m is equivalent to ESC[0m (reset)
                        (map |(or (scan-number $) 0) (string/split ";" param-str))))
                    (set current-style (parse-sgr-codes codes current-style)))
                  # Non-SGR CSI sequence — silently strip it
                  nil)
                (set i (+ j 1)))
              # Unterminated sequence — skip ESC[
              (set i (+ i 2))))
          # ESC not followed by [ — skip the ESC byte
          (do
            (++ i))))
      (do
        (buffer/push buf byte)
        (++ i))))

  (flush-buf)
  spans)

(defn strip-ansi
  "Remove all ANSI escape sequences from text, returning plain text."
  [text]
  (def spans (ansi->spans text))
  (def parts @[])
  (each span spans
    (array/push parts (span :text)))
  (string/join parts))
