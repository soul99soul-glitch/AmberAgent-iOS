# Phase 3 C6/C7 — independent Markdown review

**Result: PASS.** No actionable defect was found in the scoped C6/C7 repair. This reviewer did not implement these Markdown changes and performed a read-only source/test review; no build or test was run and no repository file was changed.

Reviewed only the requested parser, incremental detector and regression suite, against C6/C7 in `audit-chat.md` and the implementation contract in `phase-3-chat.md`.

## C6: escaped-pipe source integrity

- `ChatStreamingMarkdownBlockParser.swift:220`–229 rebuilds short/long rows from `splitTableCells(... preservingPipeEscapes: true)`.
- The escape branch at 239–245 retains the original backslash for source reconstruction. Display-cell calls continue to use the default decoded form, so `a \\| b` remains one displayed `a | b` cell without changing the existing table-cell API.
- Equal-width rows still return their untouched source. Padding and truncation use the same preserved-source cell sequence, retain the intended columns and pass literal escaped pipes to the real Markdown renderer.
- `ChatMarkdownSourceIntegrityTests.swift:7`–46 covers both padding and truncation, each with streaming and completed-row modes. It asserts source escapes, parsed display cells, and the actual `MarkdownParserImpl` / `RenderableDocument` output rather than trusting the table splitter alone.

## C7: fence ownership and full/incremental agreement

- `ChatStreamingMarkdownFenceState` stores both marker and opener run length (parser 5–11). While inside a fence, it closes only when the prefix consists of the same marker, has at least the opener's length and has only whitespace afterward (15–24).
- Shorter inner fences, a different marker, or a same-marker line with an info string remain code content. A sufficiently long matching closer with trailing whitespace closes the fence; the closer itself remains a consumed code line.
- Full `containsTable` and `parseBlocks` each use this exact shared state (39–43 and 83–105). Incremental processing uses the same state (detection 127–130), clears the prior-header candidate on every code line, rejects a pending delimiter while inside a fence (143–146), and resets the shared state on stream replacement (113–119).
- Regression cases at test lines 48–101 check shorter inner backtick fences, info-bearing false closers, and longer legal closers. The rejection cases assert the entire source stays in one text block; the legal-close case asserts only the outside table is emitted. Each case also exercises the cumulative incremental detector, and block parsing is checked in both row modes.

## Scope / evidence boundary

The fix uses one small fence-state value and one source-preservation option; it does not add a separate parser, cache or recovery path. No unrelated grammar expansion was requested or recommended. Root still owns final green execution and the required native timeline/viewport suites; this PASS is an independent code-contract review, not a claim of simulator or physical-device acceptance.
