# Phase 5 editors source audit

The initial 10-file extraction passed `xcrun swiftc -frontend -parse` and the 1500-line physical limit. Each moved block below matched its original text byte for byte after only the stated declaration visibility changes; this is stronger than a body-only hash comparison. Hashes are SHA-256 of UTF-8. The later MiniApp grants repair is audited separately below.

| Declaration/body block | Original lines | Destination lines | Original SHA-256 | Canonical destination SHA-256 | Visibility change |
|---|---:|---:|---|---|---|
| Provider image ID helper | 4-7 | `iosApp/iosApp/Settings/Providers/ProviderDetailModelSupport.swift:4-7` | `6d5c48e8025b1283c224850c2da4a93ab6dea7a95e63ad9fd96c969cce4bff85` | `0f56808da43afe743d87eb9dca30c20c5885a166b0f13b240fee4267e26db5b5` | yes |
| Provider model & endpoint helpers | 1467-1555 | `iosApp/iosApp/Settings/Providers/ProviderDetailModelSupport.swift:10-98` | `d6927ef06156cfa6457d9f5007946d5a99f0030f505380430d031f72e2a13303` | `2b99192607f38502f93f3cfde5a64db52a3ec1a2294930962400c28855342447` | yes |
| Provider draft/status/alert types | 1558-1794 | `iosApp/iosApp/Settings/Providers/ProviderDetailModelSupport.swift:101-337` | `daf9db2b23e47f086b65e4813807d915240062d6d39a5684e69f7d0d8136a7ad` | `ef2d62b04a5be266eaed1e747c14d7d9f06b4467b2598cf7ea9a175acdd6ff25` | yes |
| Provider editor and rows | 1795-2462 | `iosApp/iosApp/Settings/Providers/ProviderDetailComponents.swift:4-671` | `b6d30f7cd1c64e41dcf35e65d8eaf215953820f78ab2d77d6e8b8ddf9ff48941` | `00f5fe0fb9f791ec8af53201856153e4c003e43324903ed17328ef8e6ea53b6e` | yes |
| Runtime SSH draft/probe/trust/credential | 1340-1649 | `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentSSHProfileEditing.swift:5-314` | `fb23e100a916f869bed5613a8b5e4450d5ea02ccc72876c039fecf0163e76343` | `35b8c1f5e314e1d8f4645789c3aa23a2315faf31bba27275c245cd9f9b723fd8` | yes |
| Runtime visual and task components | 1652-2632 | `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentComponents.swift:4-984` | `3f4c5b9af29a375951c5300a7428ee0203d4f24fc05259acd8c9d2e3af86f2c9` | `bf58a85a1cf822f1ea5bcc363ffcefcdaaf565b78093cc22fc6c4823bdb8f182` | yes |
| MiniApp AI run recovery | 1281-1309 | `iosApp/iosApp/MiniApp/MiniAppAIRunRecovery.swift:3-31` | `609cb4ea0de541e326bb3cbf33b93a6637684c3703d2ab2738abdb0f3281665b` | `609cb4ea0de541e326bb3cbf33b93a6637684c3703d2ab2738abdb0f3281665b` | no |
| MiniApp system bridge and SDK delegates | 1328-1540 | `iosApp/iosApp/MiniApp/MiniAppSystemBridge.swift:9-221` | `382af9fd23c94261bd16368c841f6808801a689096fbadca661371eecf027701` | `382af9fd23c94261bd16368c841f6808801a689096fbadca661371eecf027701` | no |
| MiniApp prompts and confirmation owner | 1542-1828 | `iosApp/iosApp/MiniApp/MiniAppHostConfirmation.swift:3-289` | `fee515f7054f44537c84cef3205f1fe69d2db90911b7ae5fee5a9e0a14d7f02f` | `fee515f7054f44537c84cef3205f1fe69d2db90911b7ae5fee5a9e0a14d7f02f` | no |
| MiniApp host error | 1839-1846 | `iosApp/iosApp/MiniApp/MiniAppHostConfirmation.swift:291-298` | `dfb9662872ca168d7338dc182040c8680e9261388246f027b9e3fd5cf7da1ee9` | `dfb9662872ca168d7338dc182040c8680e9261388246f027b9e3fd5cf7da1ee9` | no |

The initial page-owner reconstruction was exact for Provider `1-3 + 9-1466`, Runtime `1-1339`, and MiniApp `1-3 + 11-1280 + 1311-1327 + 1830-1838 + 1848-1853`, apart from imports, one closing brace and listed visibility changes. Provider `saveConfig` / `persistRequestHeaders` and `fetchModels` / `cancelModelFetch` bodies match the baseline exactly. Runtime iSH policy and status-card WIP plus remote-command bodies match the baseline exactly.

Visibility exceptions: Provider page `currentModel`, `imageGenerationModel`; moved helper entrypoints and cross-file model/status/draft types; Provider component types instantiated by page. Root compiler check exposed one additional required exception: `ProviderRowValueStyle` is module-internal because `ProviderDetailView` uses its `.body`, `.mono` and `.accent` cases; only `private` on the enum declaration was removed at `Settings/Providers/ProviderDetailComponents.swift:430`, with body unchanged. `ProviderModelBadge` remains private. Runtime page nine SSH `@State` fields and nested `SSHProbeSnapshot`; SSH methods/bindings called from page; Runtime component types instantiated by page and `Text` extension used by page. No new state owner, fallback or dead-code deletion.

## MiniApp grants installed-view repair

After the initial extraction, the layout probe called `grantsSection(app)` on an uninstalled `MiniAppRunnerView`. The runner's `@Environment(\.dynamicTypeSize)` read its default value, so the AX3 screenshot did not exercise the accessibility stack branch. From the frozen runner SHA-256 `ff909e8a25bbf0867726e05e5540a09a1677d573b95338ea0456ecab1ee6e639`, the permissions section moved into `MiniApp/MiniAppPermissionGrantsSection.swift` as a real SwiftUI `View`. Its own `@Environment` resolves when the component is installed. The parent passes `app`, `systemCapabilitiesEnabled`, and `repository.grants(appId:)`; its callback still calls the existing `setGrant`, preserving repository writes, user messages, `@AppStorage`, and WebView reload identity under the parent. Grant display uses the same normalized permission lookup as `repository.grantDecision`.

| Body | Frozen runner lines -> component lines | Frozen SHA-256 | Current SHA-256 | Explanation |
|---|---:|---|---|---|
| Grants section | 355-447 -> 11-103 | `1097aefb9fe25d81c9783c3da8976d0de83a6913cdd94895d2cc41e922ddbe88` | `164d9d7f5ccee84a17363712d6bb841a40346d74e1cca1ead55f6f5b2ce7bda3` | Installed `View.body`; menu actions call the parent callback; helper calls point to moved helpers. |
| Permission display name | 660-700 -> 189-229 | `5188caaf4a4a2667c4762d59db99ed1cc1c0b1bd53b836559dfac09cc07894dc` | `43d640a06d64ba3a8867cef1c9925f8a25f61f0cbc22db45c93d13c0a8747e2f` | Renamed and deindented; labels and fallback text unchanged. The parent still uses it for activity rows and success messages. |
| Grant title | 1170-1180 -> 110-120 | `6f5498f588333e232fbb02863b106ceeeb5337a0683c618a0b3ec27cb3784f2a` | `5116a142912979053b2da9e57fa99afe687e236b67c4ff0c3fb8d48cfba805c3` | Reads passed grants with normalized key. |
| Grant tint | 1182-1194 -> 122-134 | `0537b57996ef7b5b4785cbf72e8ed66b6a628936be888e9095d8e2c9fa0ea3cf` | `4a1fc9975275b14733aa0b676918fb27973c60af3a225bf9c8adc9385a4baacc` | Reads passed grants with normalized key. |
| System-capability predicate | 1196-1203 -> 136-143 | `7cc7fc9dc69fa626654d19570684385db386443d6e3a2f80b26a2687e45157f9` | same | Byte-identical. |
| Permission description | 1205-1245 -> 145-185 | `95f9f7034ecac9aced04f53bb317340ab50bb7246e2b3239492798a48939bf7f` | same | Byte-identical. |

The new component uses existing `MiniAppCapabilityStatusRow` and `MiniAppCapabilityDivider`; it adds no test hook, repository owner or observed state. The runner is 1109 lines and the component is 229 lines. Both parse with `xcrun swiftc -frontend -parse`; `git diff --check` and new-file whitespace checks pass. Root owns the subsequent build, test and screenshot review; the earlier 995-case final-r1 run predates this repair.

## Final file SHA-256

| File | SHA-256 |
|---|---|
| `iosApp/iosApp/ProviderDetailView.swift` | `9faf2dae5f8570207d381f5c76bb74108ce3e94a0c147106ad41ff8af64b6f12` |
| `iosApp/iosApp/RuntimeEnvironmentView.swift` | `7bf50ac3ed72d67abc0645d22fd8459813a2e376ffbe22b846124184cf480018` |
| `iosApp/iosApp/MiniAppRunnerView.swift` | `29e8c8ed46142c660ad68b62d5e10ead1344288df8d5757369ed6c682ba0b967` |
| `iosApp/iosApp/Settings/Providers/ProviderDetailModelSupport.swift` | `a58b7a431438830c3484e553ea812b550a31204a4e99dac47a9d6f56ced18e86` |
| `iosApp/iosApp/Settings/Providers/ProviderDetailComponents.swift` | `da37c7af2efe6cb9288117125d87afdf9c6051e0a166a7fba1f606eeddc0b9d5` |
| `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentSSHProfileEditing.swift` | `99d794a262f38b939788883ee6d85c1a43b9a5c1d5b9c3679a53209d52c3c95f` |
| `iosApp/iosApp/Settings/Runtime/RuntimeEnvironmentComponents.swift` | `32e118ff1ae2780067cfc5449244fa9e219419c0848ab2f728bbfb6473318b6d` |
| `iosApp/iosApp/MiniApp/MiniAppAIRunRecovery.swift` | `aa49c92159ec5bc44dffafceb6264a6eca1ed1820a73f641a93a4486670c7bb3` |
| `iosApp/iosApp/MiniApp/MiniAppSystemBridge.swift` | `10b2ae1be6bd667f8aa6ef90fe4ccac4aacfd19112e6c47ac1019eb446f4c833` |
| `iosApp/iosApp/MiniApp/MiniAppHostConfirmation.swift` | `2f1120abdb4701d6db83329df84b7ca5239188c35eb436fb442fc427d9f01cde` |
| `iosApp/iosApp/MiniApp/MiniAppPermissionGrantsSection.swift` | `431a2c72ea3c0b4dcb49a9da8f7b21b1bf8c3a5ab6cdd38158ce0d0c37a1534c` |

Root owns XcodeGen membership, source guards, builds/tests, reviews and device acceptance. This worker ran no build, test, commit or push.
