# Background extraction audit

Baseline source SHA-256: `7285a10b9c3fad81e0d0e70132493ac0fbce806f417ea522603a7341b2584bf2`.

Declarations, functions, initializers and computed properties: **192/192** mapped with identical complete brace body SHA-256 and normalized signature SHA-256; 0 missing, 0 extra, 0 signature changes. Full per-declaration before/after file, line and digests: `/tmp/amber-phase5-background-bodysha.json`.

| File | Lines | SHA-256 |
| --- | ---: | --- |
| `iosApp/iosApp/IOSChatBackgroundGenerationCoordinator.swift` | 1410 | `8f168c9d0afb49ef3ad0f09684899ff098a42069d9233ff7283d4407f3e2737a` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundContracts.swift` | 253 | `88f3b005bf52a30612e86350e421bfc79ccdc1f1be4063e75fe17de7681dc10f` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundExecutor.swift` | 753 | `99d7bc2be8e04df5ef91c92177e3cc15688816b2e61d13ce978c52884206ff86` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundMessageProjection.swift` | 180 | `5175c8cd2b8507882caa59a43f93c5b345b25d18d511530c237ecd685d81f194` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundPayloadCodec.swift` | 228 | `b2a533c8c8f441fd4f01db122f60cdc7aa7232cbd6d96ea49dc4370772e5e0e6` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundRecovery.swift` | 322 | `bc0394eb41713ffa706768ac0e1117c5abace90d35242d0875aae57bdab14e74` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundResponseResumer.swift` | 586 | `d7c6ca204ccfbada0c6f3de1b9151360620c92e7f8feffa1ef685039fd96413c` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundRunState.swift` | 390 | `3f7090d52fccf780da103bdc98dfa11197392457566867ed0767f8fc76d28033` |
| `iosApp/iosApp/Chat/Background/IOSChatBackgroundTerminalWriter.swift` | 900 | `72a1ac2ce97266239672c8e9dc0d544faa7297c8f0e71960925eb93e254f973e` |

The source extraction covers all 4,954 original physical lines exactly once. New text is file imports, same-type extension wrappers and one two-line owner visibility comment; six owner properties have `private(set)` after confirming their moved extensions only read them. No method body or parameter changed. `private` was widened only where a moved helper or same-type extension references the symbol across a Swift file boundary; the full signature digest audit normalizes that access modifier.

Owner boundary: the original coordinator retains `activeJobs`, `activeRunStates`, `activeBackgroundTasks`, detached task registries, start/cancel/request-map/finish/release operations. `IOSChatBackgroundRunState` is the original single lock-protected instance used by all execution and terminal paths. `phoneSessionIsActive` injection and all terminal persistence/CAS/publication/finish paths have unchanged bodies.

Compared with the preparation packet, executor/resumer/codec/terminal/recovery are same-type coordinator responsibility extensions, not new stateful helper instances. The independent runtime review accepted this because only coordinator extensions read/write its registries; a second owner or closure-forwarding layer would make asynchronous ownership harder to trace. Cross-file read-only access to `dependencies`, `activeDetachedResponseTasks`, `foregroundResumeInFlightRequestIds`, `db`, `runStore`, and `toolLedger` now uses `private(set)` on the coordinator; their mutations remain in its original file. Other registries retain internal write access because the moved same-type methods perform real mutations.

Static checks: `swiftc -frontend -parse` on all nine files passed; `git diff --check` passed; each file is below 1,500 physical lines. Full target typecheck, tests and device/provider gates belong to Root integration and are not claimed here.
