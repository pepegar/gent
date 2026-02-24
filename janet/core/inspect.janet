# core/inspect.janet — State inspection for testing and debugging.
#
# Provides functions to dump application state as Janet data structures.
# Useful for:
#   - Automated testing: assert on state after simulated events
#   - Self-debugging: the LLM can inspect its own state via eval_janet
#   - Headless testing: verify state without a terminal
#
# Usage:
#   (import core/inspect :as inspect)
#   (inspect/full-state)
#   (inspect/chat-state)
#   (inspect/conversation-state)

(import core/conversation :as conv)
(import core/widget :as widget)
(import core/tools :as tools)
(import core/hooks :as hooks)
(import core/registers :as reg)
(import widgets/chat :as chat)

(defn conversation-state
  "Return conversation state as a table."
  []
  @{:messages (array/slice (conv/get-messages))
    :length (conv/length)
    :session-id (conv/get-session-id)
    :estimated-tokens (conv/estimate-tokens)})

(defn chat-state
  "Return chat widget state as a table."
  []
  @{:mode (chat/get-mode)
    :scrollback-count (length (chat/get-scrollback))
    :scroll-offset (chat/get-scroll-offset)
    :active (chat/active?)})

(defn scrollback-text
  "Return the scrollback as an array of plain text strings.
   Spans are flattened to their text content. Useful for asserting
   on what the user would see without caring about styles."
  []
  (def result @[])
  (each line (chat/get-scrollback)
    (if (line :spans)
      (do
        (def parts @[])
        (each span (line :spans)
          (array/push parts (span :text)))
        (array/push result (string ;parts)))
      (array/push result (or (line :text) ""))))
  result)

(defn widgets-state
  "Return widget registry state as a table."
  []
  (def result @{})
  (each name (widget/list-widgets)
    (def w (widget/get-widget name))
    (when w
      (put result name
        @{:dirty (w :dirty)
          :focused (w :focused)
          :rect (w :rect)})))
  result)

(defn tools-state
  "Return registered tool names."
  []
  (tools/list-registered))

(defn registers-state
  "Return all registers as a table."
  []
  (def result @{})
  (each name (reg/list)
    (put result name (reg/get name)))
  result)

(defn hooks-state
  "Return active hook names."
  []
  (hooks/list-hooks))

(defn full-state
  "Return the complete application state as a single table."
  []
  @{:conversation (conversation-state)
    :chat (chat-state)
    :widgets (widgets-state)
    :tools (tools-state)
    :registers (registers-state)
    :hooks (hooks-state)})
