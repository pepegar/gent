# gent — Primitives Plan

Making a composable coding agent on a lisp machine.

## 1. Buffers — The Missing Core Abstraction

Emacs's power comes from "everything is a buffer." Right now gent has files (on disk) and the conversation (in memory), but no intermediate abstraction. A **buffer** system would make editing composable:

```janet
(buffer/open "src/main.rs")       # load file into a named buffer
(buffer/current)                   # get the active buffer
(buffer/get "src/main.rs")         # get a buffer by name
(buffer/insert buf pos text)       # insert text at position
(buffer/delete buf start end)      # delete a range
(buffer/replace buf old new)       # like current edit_file but on buffers
(buffer/substring buf start end)   # extract a range
(buffer/save buf)                  # write to disk
(buffer/dirty? buf)                # has unsaved changes?
(buffer/lines buf)                 # get as array of lines
(buffer/line buf n)                # get line n
```

This makes the edit_file tool decompose into `open → replace → save`, and lets the agent (or the user's init.janet) compose richer operations. The LLM could do multi-step edits on a buffer before flushing, or operate on scratch buffers that never hit disk (like `*scratch*` in Emacs).

## 2. Marks & Regions — Composable Addressing

Instead of only `old_str` matching (fragile!), give buffers a way to address ranges:

```janet
(buffer/find buf pattern)          # returns (start . end) or nil
(buffer/find-all buf pattern)      # returns array of (start . end)
(buffer/line-range buf 10 20)      # region for lines 10-20
(buffer/narrow buf start end)      # restrict operations to a region
(buffer/widen buf)                 # undo narrow
```

This enables the agent to say "replace lines 10-20" instead of matching fragile text snippets. PEG patterns (Janet's built-in!) are perfect here.

## 3. Hooks — Extensibility Points

Emacs's hook system is what makes it infinitely customizable:

```janet
(hooks/add :before-tool-call (fn [name input] ...))
(hooks/add :after-tool-call (fn [name input result] ...))
(hooks/add :before-send (fn [conversation] ...))     # modify before API call
(hooks/add :after-response (fn [response] ...))       # post-process responses
(hooks/add :on-save (fn [path content] ...))          # lint/format on save
(hooks/add :on-error (fn [err] ...))                  # custom error handling
```

Trivial to implement — just arrays of functions keyed by event name — but it unlocks massive composability. Users could:
- Auto-format code before saving
- Log all tool calls
- Add custom approval workflows
- Transform conversation history (compression, summarization)
- Inject context before each API call

## 4. Rings / Kill Ring — History & Undo

```janet
(ring/push :kill text)             # push to the kill ring
(ring/yank :kill)                  # get most recent
(ring/yank-pop :kill)              # cycle through history

(ring/push :undo {:buf name :op :replace :old old :new new})
(undo buf)                         # revert last change to buffer
(redo buf)                         # re-apply
```

The kill ring is a generic stack/ring data structure. Use it for undo history, clipboard, search history, command history — all the same primitive.

## 5. Modes — Context-Dependent Behavior

```janet
(modes/define :review
  {:tools ["read_file" "bash" "list_files"]    # restrict available tools
   :system-prompt-extra "You are reviewing code. Be thorough."
   :hooks {:before-send (fn [conv] ...)}})

(modes/define :refactor
  {:tools :all
   :system-prompt-extra "You are refactoring. Preserve behavior."})

(modes/activate :review)
(modes/current)                    # => :review
```

Like Emacs major/minor modes. Different tasks need different tool sets and prompts.

## 6. Macros / Commands — Composable Commands

```janet
(defcommand "fix-imports"
  "Sort and organize imports in the current file"
  (fn [path]
    (def buf (buffer/open path))
    (def content (buffer/string buf))
    (def result (process/exec "isort" ["--diff" path]))
    (when (= 0 (result :status))
      (buffer/replace-all buf content (result :stdout))
      (buffer/save buf))))

(commands/list)                    # => ["fix-imports" ...]
(commands/run "fix-imports" "src/main.py")
```

Bridge between user scripting and agent tools. The agent can discover and use these without needing a full tool definition.

## 7. Registers — Named Storage Slots

```janet
(registers/set :a "some text")     # store in register a
(registers/get :a)                 # retrieve
(registers/set :last-error err)    # arbitrary data
(registers/set :_ result)          # _ = last result
```

Simple key-value store that persists across the session. The agent can stash intermediate results, the user can reference them.

## 8. Advice — Function Wrapping

```janet
(advice/around 'tools/dispatch
  (fn [original name input]
    (print "calling tool:" name)
    (def start (os/clock))
    (def result (original name input))
    (printf "tool %s took %.2fs" name (- (os/clock) start))
    result))
```

Wrap any function without modifying it. Perfect for logging, timing, approval gates, caching.

## 9. Conversation Primitives

The conversation is currently a bare array. Give it structure:

```janet
(conversation/fork)                # branch the conversation (for exploration)
(conversation/rollback n)          # remove last n turns
(conversation/summarize)           # compress old turns (call the LLM)
(conversation/inject-context msg)  # add system-like context mid-conversation
(conversation/save path)           # persist to disk
(conversation/load path)           # restore
(conversation/tokens)              # estimate token count
```

Enables the agent to manage its own context window intelligently, and the user to branch/explore/undo.

## 10. Watchers — Reactive File Monitoring

```janet
(watch/file "src/main.rs" (fn [event path]
  (when (= event :modified)
    (ui/output-info (string path " changed on disk")))))

(watch/dir "src/" (fn [event path] ...))
```

Needs a Rust native (inotify/kqueue), but makes the agent feel alive — noticing when tests pass, when files change, etc.

---

## Prioritization

| Priority | Primitive | Why |
|----------|-----------|-----|
| **P0** | **Hooks** | ✅ Implemented — `core/hooks.janet`, wired into tools + agent loop |
| **P0** | **Buffers** | ✅ Implemented — `core/buffers.janet`, full API: open/create/close, insert/delete/replace, save/reload, dirty tracking, hooks integration |
| **P1** | **Modes** | Thin layer over hooks + tool filtering, huge UX win |
| **P1** | **Conversation primitives** | Fork/rollback/save are essential for real use |
| **P1** | **Registers** | 10 lines of code, immediately useful |
| **P2** | **Commands** | Nice bridge between user scripting and agent tools |
| **P2** | **Advice** | Power-user feature, great for debugging |
| **P2** | **Kill ring / Undo** | Important once buffers exist |
| **P3** | **Watchers** | Needs Rust native, but very cool |

The key insight: **hooks + buffers + modes** together create a system where everything the agent does is interceptable, composable, and context-aware. That's what makes Emacs Emacs — not any individual feature, but the fact that everything is a surface you can grab onto.
