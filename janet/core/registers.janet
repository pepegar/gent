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

(defn push
  "Append a value to an array-valued register. Creates the array if needed.
   Use this to build a message queue in a register."
  [name value]
  (def arr (tget store name))
  (if (array? arr)
    (array/push arr value)
    (put store name @[value]))
  value)

(defn drain
  "Return a copy of an array register's contents and clear it.
   Returns an empty array if the register is missing or not an array.
   Use this to consume all queued messages atomically."
  [name]
  (def arr (tget store name))
  (if (array? arr)
    (do
      (def result (array/slice arr))
      (array/clear arr)
      result)
    @[]))

(defn clear
  "Remove a register, or clear all if no name given."
  [&opt name]
  (if name
    (put store name nil)
    (each k (keys store) (put store k nil)))
  nil)
