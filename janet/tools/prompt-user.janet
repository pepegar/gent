# tools/prompt-user.janet — Interactive dialog tool for the LLM.
#
# Presents a modal dialog to the user and waits for their response.
# Uses the async-tool pattern: dialog/show returns a result-box,
# the poll function checks it each frame.

(import core/tools :as tools)
(import core/dialog :as dialog)

(tools/register "prompt_user"
  {:description ```Ask the user a question with a modal dialog overlay. Supports three modes:
- select: present a list of options for the user to choose from
- confirm: ask a yes/no question
- input: collect free-form text input
The dialog blocks interaction until the user responds or cancels.```
   :schema {:type "object"
            :properties
            {:type    {:type "string" :enum ["select" "confirm" "input"]
                       :description "Dialog type: select (pick from options), confirm (yes/no), or input (free text)"}
             :title   {:type "string"
                       :description "The question or prompt to display"}
             :options {:type "array"
                       :items {:type "object"
                               :properties {:label {:type "string"} :value {:type "string"}}
                               :required ["label"]}
                       :description "Options for select mode. Each option needs a label; value defaults to label if omitted."}
             :default {:type "string"
                       :description "Default value for input mode"}}
            :required ["type" "title"]}
   :function (fn [input]
               (def result-box (dialog/show input))
               (tools/async-tool
                 (fn []
                   (cond
                     (result-box :cancelled)
                     [:done "User cancelled the dialog."]

                     (not (nil? (result-box :value)))
                     [:done (string (result-box :value))]

                     nil))
                 (fn [] (dialog/dismiss))))})
