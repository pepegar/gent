# Pi Image Handling

Pi does NOT directly "understand" images from pasted file paths in the editor.
There are two distinct image flows, plus the indirect path that most users hit.

## 1. CLI `@file` arguments (pre-processed)

When you run `pi @screenshot.png "What's in this?"`, the file processor
(`packages/coding-agent/src/cli/file-processor.ts`) kicks in **before** the
interactive loop:

- Detects the MIME type by sniffing the first 4100 bytes (`src/utils/mime.ts`)
- Reads the file, base64-encodes it
- Resizes if needed (max 2000x2000, max 4.5MB) using Photon WASM
  (`src/utils/image-resize.ts`)
- Sends it as an `ImageContent` attachment alongside the text in the first
  `session.prompt()` call

## 2. Ctrl+V clipboard paste (indirect)

When you paste an image via Ctrl+V in the editor
(`interactive-mode.ts:1845-1859`):

- Reads binary image data from the system clipboard (native module on
  macOS/Windows, `wl-paste`/`xclip` on Linux)
- Writes it to a **temp file** like `/tmp/pi-clipboard-<uuid>.png`
- **Inserts the file path as plain text** into the editor

This means the image is not sent inline — it follows the same path as
manually typing a file path (see below).

## 3. Pasting/typing a file path in the editor

When you paste or type a path like
`/Users/pepe/screenshots/CleanShot 2026-02-20 at 15.13.27.png` in the editor,
the image is **not** sent inline with your message. Instead:

1. The raw text (file path) goes to `session.prompt(userInput)` as plain
   text — no `images` attachment
2. The LLM sees the path and recognizes it as an image file
3. The LLM calls the **`read` tool** on that path
4. The `read` tool (`src/core/tools/read.ts:96`) detects the image MIME type
   via `detectSupportedImageMimeTypeFromFile()`
5. If it's a supported image (png/jpg/gif/webp), it reads the binary,
   base64-encodes it, auto-resizes it, and returns it as an `ImageContent` in
   the tool result
6. The LLM then "sees" the image as a vision attachment in the tool result

## Image resize strategy

`src/utils/image-resize.ts` uses Photon (Rust/WASM) with a progressive
strategy to stay under provider limits:

1. Resize to max 2000x2000 (preserving aspect ratio)
2. Try both PNG and JPEG, pick the smaller encoding
3. If still over 4.5MB, try JPEG with decreasing quality (85, 70, 55, 40)
4. If still over, progressively reduce dimensions (75%, 50%, 35%, 25%)
5. Returns a dimension note so the model knows the coordinate mapping:
   `[Image: original WxH, displayed at wxh. Multiply coordinates by N to map
   to original image.]`

## Supported formats

png, jpg/jpeg, gif, webp — detected by magic bytes, not file extension.

## Extension hook

Extensions can intercept and transform input (including images) via the
`input` event before it reaches the agent. The `InputEvent` carries both
`text` and `images`, and handlers can return `{ action: "transform", text, images }`
to modify either.
