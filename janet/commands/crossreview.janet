# /crossreview — ask the other LLM provider to review the latest response.
# Sends the last user message and last assistant response to whichever
# provider is NOT currently active, streamed with review styling.

(import core/commands :as commands)
(import core/api :as api)
(import core/conversation :as conv)
(import core/agents-md :as agents-md)
(import widgets/chat :as chat)

(defn- other-provider []
  (case (api/get-active-provider-id)
    "anthropic" "openai"
    "openai" "anthropic"
    nil))

(defn- extract-text [msg]
  "Extract plain text from a message's content (string or content blocks)."
  (def content (get msg :content ""))
  (if (string? content)
    content
    (do
      (def buf @"")
      (each block content
        (when (string? (get block :text))
          (buffer/push-string buf (get block :text))))
      (string buf))))

(defn- crossreview [args]
  (def target (other-provider))
  (unless target
    (break "Cannot determine other provider. Only anthropic and openai are supported."))
  (def target-provider (api/get-api-provider target))
  (unless target-provider
    (break (string "Provider '" target "' is not registered.")))
  (def messages (conv/get-messages))
  (when (< (length messages) 2)
    (break "Need at least one exchange (user + assistant) to review."))
  (def last-user
    (last (filter |(= "user" ($ :role)) messages)))
  (def last-assistant
    (last (filter |(= "assistant" ($ :role)) messages)))
  (unless last-assistant
    (break "No assistant response to review yet."))
  (def user-text (extract-text last-user))
  (def assistant-text (extract-text last-assistant))
  (def focus
    (let [trimmed (string/trim args)]
      (if (not= trimmed "")
        (string "\n\nFocus your review on: " trimmed)
        "")))
  (def project-context (agents-md/system-prompt-snippet))
  (def review-prompt
    (string "You are a critical peer reviewer. Another AI assistant produced "
            "the response below. Your job is to identify weaknesses, blind spots, "
            "missing considerations, and concrete improvements. Be direct and specific."
            focus
            (when (not= "" project-context)
              (string "\n\n" project-context))
            "\n\n## User request\n" user-text
            "\n\n## AI response\n" assistant-text))
  (def review-system
    "You review AI-generated plans and responses. Be concise, critical, and constructive. Use markdown.")
  (def review-conversation @[{:role "user" :content review-prompt}])
  (try
    (do
      (chat/start-review-streaming
        target
        (target-provider :name)
        review-conversation
        review-system)
      "")
    ([err]
     (string "Cross-review failed: " err))))

(commands/register "crossreview"
  {:description "Ask the other LLM provider to review the latest response"
   :usage "/crossreview [focus area]"
   :function crossreview})
