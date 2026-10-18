# Phase 6 original-test coverage and consumer status

> Historical modularization snapshot. Subsequent user-authorized test pruning is recorded in [test cleanup](../2026-10-18-test-cleanup.md); the old mapping is not a permanent test-retention rule.

**The final original-test discovery audit and recorded automated consumer gates passed.** The archived auditor ran with `--require-discovery` against Root's pre-exported Main r6, Novel r2, and DeepRead r1 result trees plus the complete Phone SwiftPM r1 log, and exited 0. It did not unpack result bundles or run a build/test. [`phase-6-coverage-final.json`](phase-6-coverage-final.json) records every original method's current declaration and any mapped target observation; [`phase-6-coverage-final-inputs.json`](phase-6-coverage-final-inputs.json) records input SHA-256 values and the tree/summary and skip-set comparisons. All 32 previously recorded static input fingerprints still match the current files.

| Consumer | Complete run | Mapped-original observations |
| --- | --- | --- |
| Main `iosAppTests` r6 | 5089 total: **5073 passed, 0 failed, 16 skipped** | 1508 found once: 1505 passed, 3 skipped |
| Novel `NovelTests` r2 | 1048 total: **1045 passed, 0 failed, 3 skipped** | 589 found once: 588 passed, 1 skipped |
| DeepRead `DeepReadTests` r1 | 109 total: **109 passed, 0 failed, 0 skipped** | No original method was moved into this target |
| Phone `AmberPhoneControlTests` r1 | 105 total: **105 passed, 0 failed** | 105 found once and passed |
| Experimental GPL r1 | Build exit 0 | Build consumer; no mapped XCTest target |

Each XCTest tree has exactly the unique case count and Passed/Failed/Skipped distribution in its exported summary. Phone's 105 distinct started/terminal pairs match its XCTest suite totals. Across mapped targets, **2202 original-method observations were found exactly once per target: 2198 passed and four explicit performance-sample skips**. The shared Novel test is expected to run once in Main and once in Novel, so target identity is part of the duplicate check. All **327 Phase 6 originals** were found and passed: 222 Main and 105 Phone. The separate Phase 4 actor-to-XCTestCase export repair was found and passed in both Main and Novel.

The initial inventory contains 5368 lexical `func test` names in 341 files. Ten P1–P6 map inputs cover 1612 original names, plus the separately documented Phase 4 actor discovery repair. Every original key has one current destination declaration. There are zero map entries outside the baseline, duplicate map entries, conflicting or convergent destinations, membership gaps, declaration gaps, missing mapped discoveries, duplicate discoveries within a supplied target, or duplicate IDs anywhere in a supplied bundle. The one `AmberControlUITests` source was already unbound from all test targets before this work; it remains an explicitly reported exception and was not silently added to Acceptance or executed.

Main r6's 16 skipped IDs are all among Main r2's 17 skipped IDs. The one formerly skipped case, `IOSIntelligentUIComponentInteractionTests/testNativeActionsUpdateOriginDraftAndFreezeReadableSubmission`, **Passed** in r6. The 16 SavedTasks AX/visual cases, including the 12 that failed in r2, all Passed in r6. Four mapped observations remain intentionally skipped: Main reasoning-stream cost, Main Council TimeProfiler, Main Novel-prose TimeProfiler, and the same Novel-prose TimeProfiler in Novel. Main r6's summary records two nonfatal runtime warnings, in Council archive and Shared Settings tests; its test result is Passed.

Two later test-fixture repairs are separate from the historical migration maps: the [Novel foreground-inventory gate repair](phase-6-novel-gate-fixture-repair.json) isolated the test from another run's global protected lease and replaced an unbounded wait, and the [BatchPolish admission repair](phase-6-batch-polish-fixture-repair.json) waited for genuine selection readiness and asserted the selection result. Both keep their class/selector and original behavior assertions; the addenda record each changed method-body SHA. Main r3 had stopped during the former hang, Main r4 ran fully with the latter as its sole failed case, and Main r5 stopped at simulator bootstrap before any actual XCTest case. Those incomplete or failed runs are not used as passing discovery evidence. Main r6 is the complete passing rerun after both repairs; Novel r2 is the complete passing Novel rerun. Historical Phase 4 maps remain unchanged.

Reproduce the final method-coverage check from the repository root using only the exported result trees:

```sh
python3 docs/reviews/2026-10-18-swift-modularization/phase-6-coverage-audit.py \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-5-council-test-moves.json \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-5-conversation-store-test-moves.json \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-6-phone-test-moves.json \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-6-parity-skill-test-moves.json \
  --xcresult-tree /tmp/amber-phase6-main-r6-tests.json \
  --xcresult-tree /tmp/amber-phase6-novel-r2-tests.json \
  --xcresult-tree /tmp/amber-phase6-deepread-r1-tests.json \
  --swiftpm-log /tmp/amber-phase6-phone-r1.log \
  --require-discovery \
  --output docs/reviews/2026-10-18-swift-modularization/phase-6-coverage-final.json
```

This audit verifies method identity, current declaration, target membership, discovery, and test outcome. The stage reviews and the two repair addenda cover body/assertion changes. The unbound UI source, manual UI, live provider, system-permission, background-duration, and physical-device acceptance are separate from these automated gates.
