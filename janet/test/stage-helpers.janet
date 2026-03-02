# test/stage-helpers.janet — Test setup combining stage provider with fake-http.
#
# Provides setup-stage which initializes the full widget stack with
# the stage provider installed, ready for scenario-driven testing.
#
# Usage:
#   (import test/stage-helpers :as sh)
#   (def w (sh/setup-stage))

(import test/fake-http :as fake)
(import core/stage :as stage)
(import widgets/chat :as chat)
(import widgets/editor :as editor)
(import core/widget :as widget)
(import core/conversation :as conv)
(import tui)

(defn setup-stage [&opt cols rows]
  "Full stage setup for testing: widgets, conversation, stage provider."
  (default cols 80)
  (default rows 24)
  (chat/reset-state)
  (fake/reset)
  (stage/reset)
  (each name (widget/list-widgets) (widget/unregister name))

  # Create all widgets like the main reactor does
  (widget/register (chat/create))
  (widget/register (editor/create))

  # Set layout function like the main reactor does
  (defn default-layout [area]
    (def ed-height 5)  # Fixed editor height for testing (includes border)
    (def [chat-area editor-area] (tui/vsplit area :fill ed-height))
    @{:chat chat-area :editor editor-area})

  (widget/set-layout-fn default-layout)
  (widget/do-layout (tui/rect 0 0 cols rows))
  (widget/focus :editor)  # Focus editor like main reactor does

  (conv/init)
  (stage/install)
  (widget/get-widget :chat))
