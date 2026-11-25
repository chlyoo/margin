# Markdown Studio

- The requested product is a macOS app. The native implementation is in `native/`; the built bundle is `build/Margin.app`. `npm start` launches that app. Web source is a superseded development reference exposed only by `npm run debug:web`.
- Read `HANDOFF.md` before resuming. Do not equate successful core checks with completed native qualification or live AI integration.
- Native verification: `bash native/build.sh --check`, then the built executable with `--ui-check --state-json` and `--quit-check`. Inspect JSON `pass`, not only exit status.
- Keep `autosaveElsewhere` and save-copy destinations out of original-file identity metadata. Preserve a snapshot before checking conflicts, and clear stale undo ranges after whole-document restoration.

- Own changes inside this folder; preserve unrelated harness work.
- Run `npm test` and the browser scenarios before declaring editing or AI flows complete. `browser-auto.js` and `browser-facts.js` require the no-network fixture server on port 4318.
- Native API credentials belong in Keychain or environment variables. Never put keys in snapshots or logs. The superseded web API must not return keys from `/api/config` or persist them in browser storage.
- A factual source URL must originate in the provider's native search result or citation payload. A URL invented in model JSON is insufficient. Unsupported factual changes must preserve the original source and show `unverified`.
- Suggestions bind to the complete document revision and target text. Editing, switching files/providers or changing review settings must invalidate pending responses and visible suggestions.
- Gate requests during IME composition. Tab may apply an actionable, current suggestion; it must never apply an unsupported factual edit.
- Normalize file text to LF before using textarea offsets; preserve original EOL and UTF-8 BOM metadata for serialization. Validate CRLF and BOM with a file-writer round trip.
- Tab acceptance must check the current selection against the suggestion range, in addition to revision and exact source text. Cursor movement does not change the document revision.
