# Home PLAT-2 first-revision actual UI validation

Latest Root-built app installed on B3C3F24B-7D39-4695-86BB-588EEC6469A4. Ordinary app launch and actual keyboard taps, no new test framework.

Passed:
- Inline typed TARGET filters Home to TARGET only (home-green-before-ax.json).
- Commit marked text if required, then tap real keyboard Search: Global query remains TARGET with title/message hits (home-green-submit-ax.json/png).
- Normal target result still opens TARGET title/body (home-green-target-smoke-ax.json).
- Inline Cancel and tapping the 会话 heading outside the field collapse the search and restore all 3 rows (home-green-inline-cancel-ax.json, home-green-outside-collapse-ax.json/png).

Failed regression / not accepted as green:
- After Inline Cancel, re-expand: native TextField still reports TARGET while all rows display (home-reopen-cancel-residual-ax.json). Adding TARGET then yields TARGETTARGET and no match. This is a mismatch between visible/native text and the state used for filtering, not just a stale row.
- Tap outside to collapse, then expand again: native TextField still reports TARGETTARGET and all 3 rows display (home-reopen-outside-residual-ax.json and home-green-reopen-empty.png). Despite its earlier planned filename, home-green-reopen-empty.png is a FAILURE screenshot and must not be cited as passed.

Root notified immediately; no source modifications by this agent. The app was stopped and simulator returned. Optional empty-library visual path was not run because the simulator includes a pre-existing task conversation outside the two Search fixtures; no data was moved for that optional path.

## Final v2 result

Root's v2 source repair was rebuilt and separately verified. Home submit retains TARGET into Global Search; inline Cancel and outside taps clear the native field, restore all rows, and reopen empty. Retyping TARGET produces exactly TARGET once with the correct filtered row. See home-v2-verification.md and the home-v2 AX/PNG evidence. The first-revision regression above remains retained as a real failed verification; it is not counted as green. The app was stopped and the simulator handed back.
