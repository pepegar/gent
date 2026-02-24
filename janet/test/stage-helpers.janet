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
  (def w (chat/create))
  (widget/register w)
  (widget/set-layout-fn (fn [a] @{:chat (tui/rect 0 0 cols (- rows 2))}))
  (widget/do-layout (tui/rect 0 0 cols rows))
  (conv/init)
  (stage/install)
  w)
