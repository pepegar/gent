# Stage script for the gent homepage asciicast.
#
# Flow:
#   1. User asks to create a ripgrep tool
#   2. LLM calls eval_janet to register the tool
#   3. LLM confirms with streaming text
#   4. User asks to search for something
#   5. LLM calls the new rg tool
#   6. LLM summarizes results with streaming text

(import core/stage :as stage)

# Response 1: tool call to eval_janet — register the rg tool
(stage/respond
  (stage/tool-call "eval_janet"
    {:code (string
      "(import core/tools :as tools)\n"
      "\n"
      "(tools/register \"rg\"\n"
      "  {:description \"Search with ripgrep\"\n"
      "   :schema {:type \"object\"\n"
      "            :properties {:pattern {:type \"string\"}\n"
      "                         :path {:type \"string\"}}\n"
      "            :required [\"pattern\"]}\n"
      "   :function (fn [input]\n"
      "               (def args @[\"--color\" \"never\" \"-n\" (get input :pattern)])\n"
      "               (when (get input :path) (array/push args (get input :path)))\n"
      "               (def result (process/exec \"rg\" (tuple/slice args)))\n"
      "               (if (= 0 (get result :status))\n"
      "                 (get result :stdout)\n"
      "                 \"No matches.\"))})")}
    :id "toolu_eval_01"))

# Response 2: streaming confirmation after tool result
# Each \n forces the markdown parser to flush, so text appears line-by-line
(stage/respond
  (stage/text-stream
    (string
      "Done — I created an `rg` tool that searches your codebase with ripgrep.\n"
      "It's registered and ready to use right now.\n"
      "No restart needed.")
    :token-delay 0.020))

# Response 3: tool call to the new rg tool
(stage/respond
  (stage/tool-call "rg"
    {:pattern "defn" :path "janet/core/hooks.janet"}
    :id "toolu_rg_01"))

# Response 4: streaming summary of results
(stage/respond
  (stage/text-stream
    (string
      "Found the hook definitions in `janet/core/hooks.janet`.\n"
      "There are functions for `add`, `remove`, `run`, and `list-hooks` —\n"
      "the full Emacs-style event system that lets you intercept tool calls, responses, and errors.")
    :token-delay 0.020))
