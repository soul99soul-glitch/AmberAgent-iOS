# Phase 6 Phone package actual XCTest discovery

Root ran `swift test --package-path iosApp/Packages/AmberPhoneControl` and captured `/tmp/amber-phase6-phone-r1.log`; the wrapper's `exitCode` is 0. The strict parser in [`phase-6-coverage-audit.py`](phase-6-coverage-audit.py) found one started and one passed event for each of **105 unique XCTest IDs**. The log's `AmberPhoneControlTests.xctest` and `All tests` summaries both state 105 executed and zero failures. The trailing Swift Testing summary reports zero additional tests.

| XCTest class | Unique discovered IDs | Result |
| --- | ---: | --- |
| `PhoneRunnerClientTests` | 104 | 104 passed |
| `RunnerPhaseTimingTests` | 1 | 1 passed |

All 105 IDs match the Phase 6 Phone map's 105 original package methods by current target/class/method. There are zero missing mapped IDs, zero unexpected IDs, and no repeated starts or terminal events. The [per-method report](phase-6-coverage-phone.json) records each old method, current ID, result, log SHA-256, map SHA-256, and Root's command/status metadata. This is actual SwiftPM XCTest discovery and execution evidence for the Phone package; it does not establish Main, Novel, or DeepRead discovery.

The local Swift 6.4 default swiftbuild run previously accepted `--xunit-output` without writing XML. This review therefore uses the complete XCTest log and its two suite totals; no XML was fabricated. Root will pass this same log as `--swiftpm-log /tmp/amber-phase6-phone-r1.log` to the final multi-product `--require-discovery` audit after the iOS result bundles finish. No build or test was started by this audit agent.
