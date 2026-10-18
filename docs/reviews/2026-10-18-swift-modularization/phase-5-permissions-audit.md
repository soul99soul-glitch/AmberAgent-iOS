# Phase 5 permission/widget extraction audit

All original ranges below refer to the verified snapshot in `/tmp/amber-phase5-source-baseline/files/iosApp/iosApp`. All migrated declaration bodies and catalog entries compare byte-for-byte, except listed access-modifier changes. SHA256 values are of the original declaration block.

| Original range -> new file/range role | Original SHA256 | Comparison |
|---|---|---|
| IOSPermissionModels 1-179 -> IOSPermissionModels model declarations | `2346b3ed9532b4a3da136b19e702abda0f23248cc55afe2350e0f234c8fdec75` | byte-identical |
| IOSPermissionModels 180-1582 -> Infrastructure/Permissions/IOSCapabilityRegistry catalog+derived sets | `b09c908ad88946d989aefcf88947000532ca713545f67e49f1dc0ca6a9559de0` | byte-identical |
| IOSPermissionModels 1599-1605 -> IOSCapabilityRegistry composite requirements | `914645a15c9fe8ddac310301ff2137d3528d2887d990de7f34b36d2be61c3bdc` | byte-identical |
| IOSPermissionModels 1583-1598 + 1606-1623 -> IOSPermissionModels registry lookups | `f9a78e109c85c8da0aa1ec2bc0aec70b9239236dbae2a4e86b5086bb802edba1` | byte-identical |
| IOSPermissionModels 1624-1689 -> IOSPermissionModels registry builders | `9e055b25fe105abe558b1bbf601a60069011c2ea42a0f91cfb16e9ff79b80f87` | Two `private static func` -> `static func` (cross-file access); body unchanged |
| IOSPermissionModels 1691-1708 -> IOSCapabilityRegistry gate constants | `aa99daadcfa255e7b62e5bb6616eb63496d521de0a028d686762c462fa27891f` | Only `freshHighRiskGate` private -> internal for builder |
| IOSPermissionModels 1710-1748 -> IOSPermissionModels enforcement/localization | `3e3406e588e791e99a3249d1281de2cb39003b1b96361563d1854130fddf88be` | byte-identical |
| IOSPermissionModels 1750-2093 -> Infrastructure/Permissions/IOSPermissionPolicyStore all policy/store declarations | `4a1842bc8c289331140b41a60251636b83ae771ae2d0a63af41b942adbeba139` | Byte-identical body, including unsupported-policy WIP |
| IOSSystemPermissionCoordinator 1-501 -> original coordinator router | `f36e846cc430f02288d36160e2abf5f0c9235b7878ab19099260986217efefea` | Three private -> internal access modifiers; remaining body unchanged |
| IOSSystemPermissionCoordinator 503-1553 -> Infrastructure/Permissions/IOSSystemPermissionRequests framework methods/delegate requesters | `5b8980aa1461f641d3c3f54c5a7c5af24afddc78d1392676d1fd286897989dbe` | Cross-file private -> internal access modifiers; body unchanged |
| IOSGenerativeWidgetParser 1-964 + 1573-1652 -> original parser/models/detector/shared helpers | `af27ea2f9923e10676eb9ea770f678761e81fc1f800ad697f86b8af484406159` | Byte-identical body |
| IOSGenerativeWidgetParser 965-1126 -> GenerativeUI/IOSVChartSpecValidator | `682f12148cfd773b3bd57073f38e736a1d71eb50693079e5711491d6f68dffd4` | Byte-identical body |
| IOSGenerativeWidgetParser 1127-1572 -> GenerativeUI/IOSGuizangHtmlDeckValidator | `9a170bdbb75e557fa613a1801570841b528c89c8875d4297271520d5022a2394` | Byte-identical body |

## Structural checks

- Registry: 101 unique ordered IDs; SHA256 `12d1f891dba3385fd5c3a1ed3e12abe66b7baec39dbd2964dca8c61d6a091029`. Original catalog entry block 180-1560 remained byte-identical, preserving all capability fields.
- `IOSPermissionModels.swift`: 321 lines, SHA256 `30a51acc89cf8657ee7b9ffb90adefb2b0b3e5fa4ea7d97b2a560949d14e8b3f`.
- `Infrastructure/Permissions/IOSCapabilityRegistry.swift`: 1430 lines, SHA256 `c7a5c1cb8d11453b98f8e72545eefb5f7f5f46cdd042ba1d4e8b4288328a11a2`.
- `Infrastructure/Permissions/IOSPermissionPolicyStore.swift`: 347 lines, SHA256 `347218d02e26dc57860e4f52011755e8d32a4334249d413d50c9f5827b5d273b`.
- `IOSSystemPermissionCoordinator.swift`: 501 lines, SHA256 `968e9cfc089cc463b62dbeef4096af868bf1d25a46639dd5ce1cccf439f9ef7c`.
- `Infrastructure/Permissions/IOSSystemPermissionRequests.swift`: 1143 lines, SHA256 `0d25c7356db2b8e40d24f1a44fa9a15c7260813e3ddf37e8d97cea7beca44ce6`.
- `IOSGenerativeWidgetParser.swift`: 1044 lines, SHA256 `af27ea2f9923e10676eb9ea770f678761e81fc1f800ad697f86b8af484406159`.
- `GenerativeUI/IOSVChartSpecValidator.swift`: 164 lines, SHA256 `33fc428fee9c87e8f28559f69ee0069e4b2e70a9d68f8f50ad773ef46729f306`.
- `GenerativeUI/IOSGuizangHtmlDeckValidator.swift`: 448 lines, SHA256 `f182dbe0b76e21df4368e3b34b0c0abb37b442fd0779215c84f0c2659fe78b4a`.

Swift frontend parse and Git whitespace checks are run separately. Root owns YAML, generated project, length guards, builds and XCTest gates. This owner did no build or device acceptance.

## Completion gate

- Reconstructed all eight final files from the SHA-verified snapshots and compared whole-file contents byte-for-byte. The only differences from extracted source bodies are the explicitly listed Swift access modifiers, new file imports, declaration placement, and one trailing blank-line cleanup.
- `swiftc -frontend -parse` passed for all eight result files together.
- `git diff --check` passed for the three tracked files. All five new files were checked for trailing whitespace and final newline in the reconstruction script.
- One `code-simplifier` maintainability review found the ownership boundaries direct: registry data and derived sets, models/lookup/builders, policy persistence, coordinator routing, framework requests, widget parser/helpers, and two validators each have one clear file. The module-internal access expansion is limited to symbols needed across the new file boundaries. No additional code change was justified.
- No build, XCTest, simulated system-permission flow, physical device or provider acceptance was run by this owner. Root owns YAML/project source closure and build/test validation.
