# Registers — named storage slots.
# A simple key-value store that persists across the session.
# The agent can stash intermediate results, the user can reference them.
#
# Usage:
#   (import core/registers :as reg)
#   (reg/set :a "some text")
#   (reg/get :a)              # => "some text"
#   (reg/set :_ result)       # convention: _ = last result
#   (reg/list)                # => @[:a :_]

# Capture builtins we shadow
(def- tget get)

(var- store @{})

(defn set
  "Store a value in a named register."
  [name value]
  (put store name value)
  value)

(defn get
  "Retrieve a value from a named register, or default if not found."
  [name &opt default]
  (tget store name default))

(defn list
  "Return all register names."
  []
  (sort (keys store)))

(defn clear
  "Remove a register, or clear all if no name given."
  [&opt name]
  (if name
    (put store name nil)
    (each k (keys store) (put store k nil)))
  nil)
