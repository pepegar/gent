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

(defn style
  "Create a style struct. All keys are optional.
   Supported keys: :fg :bg :bold :dim :italic :underline :reversed"
  [& args]
  (struct ;args))

(def style-default
  "Empty style that changes nothing."
  (struct))

(defn style-merge
  "Merge two styles. Values in `over` override those in `base`.
   nil values in `over` do NOT override (they are skipped)."
  [base over]
  (def entries @[])
  (def all-keys @{})
  (when base
    (eachp [k _] base (put all-keys k true)))
  (when over
    (eachp [k _] over (put all-keys k true)))
  (eachp [k _] all-keys
    (def v (if (and over (not (nil? (get over k))))
             (get over k)
             (get base k)))
    (when (not (nil? v))
      (array/push entries k)
      (array/push entries v)))
  (struct ;entries))

(defn style->sgr
  "Convert a style to an ANSI SGR escape sequence string.
   Returns empty string for nil/empty styles."
  [s]
  (if (or (nil? s) (= s style-default))
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
