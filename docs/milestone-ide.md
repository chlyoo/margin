---
artifact_id: artifact-2026-11-18-markdown-studio-milestone-ide
parent_id: artifact-2026-11-18-markdown-studio
artifact_type: sdlc-milestone
state: implementing
traceability_to: [artifact-2026-11-18-markdown-studio]
version: 1
authors: [claude]
last_updated: 2026-11-20
---

# Workspace IDE: follow what the coding agent did, step by step

**Why**: a coding agent hands back one final diff. The reviewer cannot see the order of the edits or the reason for each one, so review is slow. This slice records an agent run as ordered steps (reason + file diff) and lets the reviewer walk them and accept or reject each.

| Acceptance | Contract |
| --- | --- |
| AC-IDE-1 | A folder opens as a workspace window: file tree, Markdown files in the existing source/rendered pane, other text files in a code view with line numbers and syntax colouring |
| AC-IDE-2 | An instruction typed in the window runs Claude Code headless in that folder; follow-up instructions continue the same session; the run can be stopped |
| AC-IDE-3 | Every batch of agent tool calls that changes files on disk becomes one step: the agent's stated reasoning since the previous step, the tools it ran, and each file's before/after text. Edits made by shell commands are captured too |
| AC-IDE-4 | The reviewer walks steps in order, sees reason and diff, accepts (Tab) or rejects (Delete). Reject restores the step's previous text only when the step's result is still present in the file; otherwise it refuses and changes nothing |
| AC-IDE-5 | A simple terminal runs shell commands in the workspace and shows agent activity live. It is a line log, not a TTY emulator |
| AC-IDE-6 | Recorded sessions persist and reopen for later review |
| AC-IDE-7 | `margin <folder>` opens the folder from the command line |
| AC-IDE-8 | One command formats the open file with the language's installed formatter; a step can also be rejected one changed part at a time |
| AC-IDE-9 | A real terminal (PTY) tab runs full-screen programs in the workspace folder |

**Decisions**
- Steps are attributed by what changed on disk between tool results, not by tool inputs, because agents also edit through `sed`, scripts and formatters.
- "Reasoning" is the assistant's visible text (and thinking text when the stream carries it). The measured stream (`claude -p --output-format stream-json`, v2.1.327) often carries empty thinking blocks, so the run appends a system-prompt line asking for a one-sentence reason before each change.
- Agent launch: `claude -p --output-format stream-json --verbose --permission-mode acceptEdits --allowedTools Read,Glob,Grep,Edit,Write,Bash`, started through the user's login shell so account configuration is inherited. Shell access can be switched off in the window.
- Reject never uses `git checkout`, `stash` or `reset`.
- Terminal: no new dependency. The first slice shipped a line shell only; on 2026-11-20 an in-house PTY terminal (`native/Terminal.swift`) was added beside it (FR-IDE-9), still without a third-party package.
- Formatting runs the formatter the person already has installed, by absolute path, with the text on stdin; the app bundles none (FR-IDE-8).

**Non-goals**: LSP, debugger, git UI, multi-root workspaces.

**Known limits**: files over 1 MiB, non-UTF-8 files, ignored build folders and secret-like files (`.env*`, keys, credentials) are never snapshotted, so agent changes to them do not appear as steps. Edits a person makes outside this window during a run are attributed to the running step.

SRS: FR-IDE-1..9 and NFR-IDE-1 in [srs.md](srs.md). Verification: `native/Checks.swift` and `--ui-check`, by replaying `native/fixtures/agent-stream.jsonl`; no live AI in checks.
