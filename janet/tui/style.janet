# tui/style.janet — Colors, modifiers, and composable styles.
#
# Styles are immutable structs. Merge them with style-merge (later overrides earlier).
# Convert to ANSI SGR escape sequences with style->sgr.
#
# Usage:
#   (def s (style :fg :red :bold true))
#   (def s2 (style :bg :blue :italic true))
#   (def merged (style-merge s s2))

# ── Color helpers ──────────────────────────────────────────────

(defn rgb
  "Create an RGB color tuple."
  [r g b]
  [:rgb r g b])

(defn color-indexed
  "Create a 256-color index."
  [n]
  [:indexed n])

(def- fg-codes
  {:black "30" :red "31" :green "32" :yellow "33"
   :blue "34" :magenta "35" :cyan "36" :white "37"
   :bright-black "90" :bright-red "91" :bright-green "92" :bright-yellow "93"
   :bright-blue "94" :bright-magenta "95" :bright-cyan "96" :bright-white "97"
   :default "39"})

(def- bg-codes
  {:black "40" :red "41" :green "42" :yellow "43"
   :blue "44" :magenta "45" :cyan "46" :white "47"
   :bright-black "100" :bright-red "101" :bright-green "102" :bright-yellow "103"
   :bright-blue "104" :bright-magenta "105" :bright-cyan "106" :bright-white "107"
   :default "49"})

(defn- color->fg [c]
  (cond
    (nil? c) nil
    (keyword? c) (get fg-codes c)
    (and (tuple? c) (= (c 0) :rgb))
    (string/format "38;2;%d;%d;%d" (c 1) (c 2) (c 3))
    (and (tuple? c) (= (c 0) :indexed))
    (string/format "38;5;%d" (c 1))
    nil))

(defn- color->bg [c]
  (cond
    (nil? c) nil
    (keyword? c) (get bg-codes c)
    (and (tuple? c) (= (c 0) :rgb))
    (string/format "48;2;%d;%d;%d" (c 1) (c 2) (c 3))
    (and (tuple? c) (= (c 0) :indexed))
    (string/format "48;5;%d" (c 1))
    nil))

# ── Style construction ────────────────────────────────────────

(defn- style->sgr-raw
  "Compute the ANSI SGR escape sequence string from style keys."
  [s]
  (if (or (nil? s) (= 0 (length s)))
    ""
    (do
      (def codes @[])
      (when-let [fg (color->fg (get s :fg))]
        (array/push codes fg))
      (when-let [bg (color->bg (get s :bg))]
        (array/push codes bg))
      (when (get s :bold) (array/push codes "1"))
      (when (get s :dim) (array/push codes "2"))
      (when (get s :italic) (array/push codes "3"))
      (when (get s :underline) (array/push codes "4"))
      (when (get s :reversed) (array/push codes "7"))
      (if (empty? codes)
        ""
        (string "\x1b[" (string/join codes ";") "m")))))

(defn style
  "Create a style struct. All keys are optional.
   Supported keys: :fg :bg :bold :dim :italic :underline :reversed"
  [& args]
  (def raw (struct ;args))
  (struct ;args :_sgr (style->sgr-raw raw)))

(def style-default
  "Empty style that changes nothing."
  (struct :_sgr ""))

(defn style-merge
  "Merge two styles. Values in `over` override those in `base`.
   nil values in `over` do NOT override (they are skipped)."
  [base over]
  (def entries @[])
  (def all-keys @{})
  (when base
    (eachp [k _] base (when (not= k :_sgr) (put all-keys k true))))
  (when over
    (eachp [k _] over (when (not= k :_sgr) (put all-keys k true))))
  (eachp [k _] all-keys
    (def v (if (and over (not (nil? (get over k))))
             (get over k)
             (get base k)))
    (when (not (nil? v))
      (array/push entries k)
      (array/push entries v)))
  (def merged (struct ;entries))
  (struct ;entries :_sgr (style->sgr-raw merged)))

(defn style->sgr
  "Convert a style to an ANSI SGR escape sequence string.
   Returns the precomputed :_sgr when present."
  [s]
  (if (nil? s)
    ""
    (if-let [cached (get s :_sgr)]
      cached
      (style->sgr-raw s))))

(defn style=
  "Fast style equality. Compares precomputed SGR strings and :link."
  [a b]
  (cond
    (and (nil? a) (nil? b)) true
    (or (nil? a) (nil? b)) false
    (and (= (get a :_sgr) (get b :_sgr))
         (= (get a :link) (get b :link))) true
    false))

# ── OSC 8 hyperlink helpers ───────────────────────────────────

(def osc8-close
  "OSC 8 close sequence (BEL terminator)."
  "\x1b]8;;\x07")

(defn osc8-open
  "OSC 8 open sequence for a URL (BEL terminator)."
  [url]
  (string "\x1b]8;;" url "\x07"))
