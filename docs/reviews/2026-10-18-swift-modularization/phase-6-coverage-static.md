# Phase 6 original-test static coverage audit

The static audit passed against the current working tree after both Phase 6 maps appeared. It did **not** consume XCTest results or run a build/test. The machine-readable result is [`phase-6-coverage-static.json`](phase-6-coverage-static.json); [`phase-6-coverage-static-inputs.json`](phase-6-coverage-static-inputs.json) pins the map, auditor, baseline, project membership specifications, and 14 Phase 6 destination source file SHA-256 values used for this snapshot. Rerun after any of those inputs changes.

The default baseline is now the byte-identical archived [`phase-6-coverage-baseline-test-inventory.json`](phase-6-coverage-baseline-test-inventory.json), copied from `/tmp/amber-swift-modularization-baseline-20261018-010059/test-method-inventory.json` (SHA-256 `4c8e14bce9d7a0186c936274052dc42923901bf36af3242ae20c08eea8429c40`). It contains only original relative test file paths and 5368 method names, not test source bodies. Set `AMBER_SWIFT_BASELINE_DIR` explicitly to read a different snapshot directory. Re-running static coverage after this data-source change produced identical counts and gap lists.

| Original suite | Mapped original methods | Current test target |
| --- | ---: | --- |
| `PhoneRunnerClientTests.swift` | 105 | `AmberPhoneControlTests` Swift package |
| `IOSPhoneGoalLoopTests.swift` | 77 | Main `iosAppTests` |
| `IOSPhoneControlControllerTests.swift` | 46 | Main `iosAppTests` |
| `IOSParityRedLightTests.swift` | 61 | Main `iosAppTests` |
| `IOSSkillMcpToolsTests.swift` | 38 | Main `iosAppTests` |
| **Phase 6** | **327** | **105 package, 222 Main** |

The two native `schemaVersion: 1, phase: 6` maps were passed separately as repeatable `--extra-map` arguments; no merged or rewritten map was used. All 327 old `(file, method)` keys occur in the original inventory. Their destinations have a single `func test…` declaration in the mapped file (327/327), a nonempty XCTest class, and expected source membership. File moves account for 169 methods. Across all 5368 original methods, the current six P1–P4 maps plus P5 and P6 maps cover 1612; the known Phase 4 actor discovery repair is one additional explicit exception. The static report has zero unknown-baseline map entries, duplicate map entries, conflicting/convergent destinations, new target membership gaps, and declaration gaps. The pre-existing unbound `AmberControlUITests` source is still reported separately as one exception and is not newly added to an executable scheme.

The report's 2202 `discovery_gaps` mean **no final result bundle or SwiftPM log was supplied to this static pass**. They do not indicate that 2202 tests failed or disappeared. Actual per-target discovery, skipped/failed status, and duplicate runtime IDs remain pending final Main/Novel/DeepRead `.xcresult` bundles and a complete Phone SwiftPM XCTest log. SwiftPM 6.4's accepted `--xunit-output` flag did not produce XML in the observed 105/105 baseline run; the auditor's `--swiftpm-log` path validates started/terminal pairs and both XCTest totals instead of inventing XML. Method body and assertion equivalence is covered by the stage maps/reviews, not by this lexical declaration check.

Static command, run from repository root:

```sh
python3 docs/reviews/2026-10-18-swift-modularization/phase-6-coverage-audit.py \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-5-council-test-moves.json \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-5-conversation-store-test-moves.json \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-6-phone-test-moves.json \
  --extra-map docs/reviews/2026-10-18-swift-modularization/phase-6-parity-skill-test-moves.json \
  --output docs/reviews/2026-10-18-swift-modularization/phase-6-coverage-static.json
```

For the final runtime gate, repeat the four maps above, add each final product `--xcresult` and `--swiftpm-log PATH`, then use `--require-discovery --output .../phase-6-coverage-final.json`. The auditor fails if any mapped method lacks discovery in any source target, if a result bundle duplicates an XCTest ID, or if either Phase 5 or Phase 6 map is missing. Final result paths and exit statuses must come from Root's completed consumer runs; this static snapshot is not runtime acceptance.
