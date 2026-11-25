---
artifact_id: artifact-2026-11-18-markdown-studio-srs
parent_id: artifact-2026-11-18-markdown-studio-milestone
artifact_type: sdlc-srs
state: reflecting
version: 3
last_updated: 2026-11-20
---

# Native acceptance contract

Canonical acceptance: [requirements.json](requirements.json). Qualification is incomplete; see [native evidence](native-evidence.json) and [handoff](../HANDOFF.md).

| ID | Priority | Acceptance |
| --- | --- | --- |
| FR-MD-1 | P0 | Source, preview and split modes; independently selectable panes; pointer and keyboard resize; one canonical document; rendered pane is edited in place as rendered text and the Markdown source follows; pasted rich text converts to Markdown; `#tag` renders as a chip; Shift+Enter inserts a line break; formatting toolbar limited to Markdown constructs; link bubble, Cmd+K and auto-linking |
| FR-MD-2 | P0 | GFM headings, tables, tasks and highlighted fences render; scripts/unsafe URLs stripped; external images opt-in |
| FR-MD-3 | P0 | Native NSDocument open/save, UTF-8 BOM and CRLF format preservation; crash-recovery snapshots |
| FR-MD-4 | P0 | Provider/model selection; live 1200ms paragraph review when configured; manual correction; original/replacement/reason; Tab accepts/Esc rejects; stale suggestions cannot apply; IME-safe |
| FR-MD-5 | P0 | AI factual, wording and grammar review; native provider-search URL provenance; fact-labelled and numeric changes require evidence; semantic classification and relevance remain model judgments |
| NFR-SEC-1 | P0 | No localhost server needed; API credentials in macOS Keychain/environment only; bundled sanitized preview; bounded review and stale-result checks |
| FR-MD-6 | P0 | Native macOS .app with source/rendered/split view, native file editing and AI settings |
| FR-MD-7 | P0 | Debounced durable draft autosave and original-file autosave when saved, truthful errors, conflict detection |
| FR-MD-8 | P0 | Immutable timestamped versions with preview, restore-as-new-version and reopening recovery |
| FR-IDE-1 | P0 | Folder workspace window with file tree; ignored build folders and secret-like files hidden; Markdown opens in the source/rendered pane; other text files open in a code view with line numbers and syntax colouring; edits autosave with external-change guard |
| FR-IDE-2 | P0 | Agent run recorded as ordered steps; a step = reasoning text since the previous step + tools run + per-file before/after; changes made by shell commands are captured; parallel tool calls form one step; secret-like, ignored, oversized and non-UTF-8 files are never snapshotted |
| FR-IDE-3 | P0 | Step review: ordered timeline, reason and line diff per step, previous/next, accept marks and advances, reject restores the previous text only when the step's result is still present (whole file, or every changed hunk found exactly once); otherwise refuses and writes nothing |
| FR-IDE-4 | P0 | Typed instruction runs Claude Code headless in the workspace; follow-ups resume the same session; stop button; non-JSON output is shown, not dropped |
| FR-IDE-5 | P1 | Simple terminal: shell command runs in the workspace, output streams into the log, `cd` persists, exit status shown; agent tool activity appears in the same log |
| FR-IDE-6 | P1 | Recorded sessions persist per workspace and reload with decisions |
| FR-IDE-7 | P1 | `margin [folder\|file ...]` on PATH opens each folder as a workspace window and each file as a document in the running app, or launches it; an already open folder reuses its window; a missing path prints an error and exits 1 |
| FR-IDE-8 | P1 | "코드 정리" (⌥⌘L, button) runs the installed formatter for the open file's language (Python: ruff, then black; Go: gofmt; Rust: rustfmt; JS/TS/JSON/CSS/HTML/YAML/Markdown: prettier; others listed in `native/Format.swift`) on the editor text and applies the result as one undoable edit, then saves; a failing formatter, a timeout or text edited meanwhile changes nothing and shows the reason; a missing tool names what to install. In the code view Enter keeps the line's indent and adds one level after an opening line, Tab and Shift-Tab indent and outdent |
| FR-IDE-9 | P1 | A terminal tab runs the login shell on a pseudo-terminal in the workspace folder: full-screen programs (vim, less, top) draw and take keys, Ctrl-C interrupts, the window size reaches the program, Hangul input and double-width characters work, text can be selected, copied and pasted, scrollback is kept; terminal contents are never written to disk |
| FR-IDE-10 | P1 | Find, as in Sublime Text: ⌘F opens the editor find bar (a one-line selection becomes the search string; in the markdown preview it switches to source first), ⌥⌘F find and replace, ⌘G / ⇧⌘G next and previous match, ⌃⌘G select all matches, ⌘E use selection for find, ⌘J scroll to selection. ⇧⌘F searches every tracked file under the workspace folder with case-sensitive, case-insensitive, whole-word and regex modes and a regex file mask over the relative path; an invalid regex shows an error and searches nothing; Enter or double-click opens the hit with its range selected; secret files are never searched |
| FR-IDE-11 | P2 | ⌘K ⌘B toggles the workspace file tree, as in Sublime Text; the choice persists across launches; ⌘B alone and ⌘V after ⌘K are not intercepted |
| FR-IDE-12 | P1 | The Claude log and instruction line live in a right side panel toggled by ⌥⌘B; the terminal is a bottom panel toggled by ⌃` (open, focus, close when focused); status sits in a window status bar; the one-line shell mode is removed; the log shows the instruction and Claude's reply under names, renders Markdown (headings, lists, code, emphasis) and keeps tool calls small |
| NFR-IDE-1 | P0 | Checks replay a recorded stream with no live AI, no Keychain and no synthetic input; a workspace scan tracks at most 20000 files at first scan (new files up to twice that) of at most 1 MiB each, off the main thread |
