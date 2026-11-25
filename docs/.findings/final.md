## Closeout

| Item | Result |
| --- | --- |
| Scope | Final versions of `ai.mjs`, `server.mjs`, `public/{app,core,render,index}`, the four browser scripts, `fixture-server.mjs`, node tests, `package.json`, `.gitignore`, SRS, brief and evidence files. I used no tools and made no provider calls. |
| Node evidence | 17 of 17 tests pass (`node-evidence.txt`). That is 3 more than the previous 14: CRLF/BOM round trip, the selection guard, and a numeric change mislabeled as grammar. |
| Browser evidence | 45 checks pass (`browser-evidence.json`): 20 basic, 6 files, 9 auto, 10 facts. Live provider calls are `not-run`. |
| `.env` handling | `package.json` `start` uses `--env-file-if-exists=.env`. `.gitignore` excludes `.env` and `.env.*` but keeps `!.env.example`. |
| Cooldown | The pass results for marked 18.1.3, DOMPurify 3.4.17, Prism 1.30.0 and @types/trusted-types 2.0.7 come from your statement. I did not see the probe output itself. |

### Status of the previous M findings

| Finding | Status | Evidence |
| --- | --- | --- |
| Remote resources load outside `<img>` | Resolved | `render.js`: `FORBID_ATTR` includes `background` and `poster`. `[src]:not(img)` is removed, and every `input` other than a checkbox is removed. `RETURN_DOM_FRAGMENT: true` is set. `browser-check.js` checks `input[src], [background], [poster]`. The CSP still allows `img-src http(s)`, but only an `<img>` that passed the opt-in can make a request, so this is acceptable. |
| CRLF rewrite and offset drift | Resolved | `core.js` `decodeDocument` converts the file to LF and records `{eol, bom}`. `encodeDocument` restores them. `app.js` `openFile` and `saveFile` apply the format, and the draft also stores it. Covered by the node CRLF+BOM round trip and by `browser-files.js` "CRLF and BOM preserved by file writer". |
| Tab applies a suggestion to a paragraph away from the cursor | Resolved | The keydown handler calls `selectionMatches`. On a mismatch it invalidates the suggestion and inserts the default indentation. `stats()` (click/keyup/select) and the response handling in `askCorrection` also check the selection. Covered by `browser-facts.js` "moving cursor never applies a remote paragraph suggestion". |
| Fact gating trusts the model's self-reported category | Resolved (documented limitation plus a partial server guard) | `ai.mjs` forces a numeric change to `fact`, so it needs a `contradicted` claim, a substring match in the original, and a search result. The remaining limitation is stated in the last paragraph of the SRS and in the `index.html` footer ("사실 수정은 근거를 확인해 주세요"). |

The L items I raised before (automatic review turning off on 429, and re-review after an accepted edit) are also resolved: 429 now calls `scheduleCorrection`, and `sourceInsertion` suppresses auto review.

## Protocol Benefit

| Sub-score | Score | Basis |
| --- | --- | --- |
| Decision delta | 0/3 | This round did not change the approach. |
| Constraint discovery | 1/2 | Only one new low-severity issue found: mixed line endings collapse to the first EOL (below). |
| Verification impact | 2/2 | All four M findings now have matching node or browser checks. |
| Correct apply | 1/1 | An independent re-review was appropriate after fixes that touch security and file integrity. |
| Observed rework avoided | 1/2 | The CRLF rewrite and the remote-resource vectors were found by reading the code and fixed before release. No regression was observed at runtime. |

## Findings

No blockers remain. Only these L items are left:

| Sev | Location | Issue |
| --- | --- | --- |
| L | `core.js` `decodeDocument` | A file with mixed line endings is saved with every EOL replaced by the first one found. This is a silent rewrite and affects only files that mix EOL styles. |
| L | `app.js` keydown | When a suggestion cannot be applied (unverified) and the cursor is inside its range, Tab returns without `preventDefault`, so focus leaves the editor. This is still unfixed. |
| L | `app.js` `saveFile` | With a `.txt` handle the displayed name is still `safeFilename(handle.name)`. The save does not check `lastModified` before overwriting. |

## Verdict

**accept.** The claims "file preservation", "external images blocked" and "Tab applies only the suggestion for the current paragraph" are now backed by code and tests. Provider-hosted search and live provider responses remain unverified, because these runs used mocks only.
