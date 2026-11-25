---
artifact_id: artifact-2026-11-18-markdown-studio-milestone
parent_id: artifact-2026-11-18-markdown-studio
artifact_type: sdlc-milestone
state: reflecting
traceability_to: [artifact-2026-11-18-markdown-studio]
version: 3
authors: [codex]
last_updated: 2026-11-18
---

# Local editor acceptance

| Acceptance | Contract |
| --- | --- |
| AC-1 | Source / preview / split selection with shared document and adjustable panes |
| AC-2 | Sanitized GFM rendering with code highlighting |
| AC-3 | Native file open/save, EOL/BOM preservation, 1s autosave, immutable version preview and restoration |
| AC-4 | Live fact, wording and grammar review via Vercel AI Gateway or Claude; Tab accepts, Esc dismisses; stale results rejected |
| AC-6 | Native web-search evidence; unverified factual edits cannot apply |
| AC-5 | Native Keychain credentials and isolated bundled preview; no localhost runtime |
| AC-7 | Native macOS Margin.app with headless verification |

SRS: [requirements.json](requirements.json). Verification: native core, UI and quit checks; final review remains pending, tracked in `rtm.md`.
