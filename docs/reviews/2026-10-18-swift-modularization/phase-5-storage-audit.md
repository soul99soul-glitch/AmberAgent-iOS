# Phase 5 storage/compaction source audit

Generated: 2026-10-17T20:53:08.194625+00:00

Scope: four owned originals and eight derived Swift files. This is a source-only audit; Root owns build/test.

## File lengths and SHA-256

| Lines | File | Current SHA-256 |
| ---: | --- | --- |
| 478 | `Chat/Compaction/IOSContextCompactionBudget.swift` | `bfabace6cd16651fd46470dcd32f78f15bf116678aa4000a26a30d71d8cbf4cd` |
| 423 | `Chat/Compaction/IOSContextCompactionHandoffCodec.swift` | `f2055245b3b1e3f9512fd8c95fa546e7871389f823015eb95bc86fc6d624f913` |
| 244 | `Chat/Compaction/IOSContextCompactionPreparedContext.swift` | `4c3ad3b846484607371b74a154c2ed033f5d770b6375f755fa03461e60b0c25f` |
| 280 | `Chat/Storage/IOSConversationBranching.swift` | `f57549ab1fd3e13bb816f962f19e7884c67fbfe33f4348bf5624fd5ee491d87f` |
| 244 | `Chat/Storage/IOSConversationContentAccess.swift` | `6e5be256ff5c32d7b6bb48d3af8b457be552861742ee0fcac91c1ca2638adbb0` |
| 1043 | `DocumentAccessStore.swift` | `22a1315fadd42c164af1c230ce5d8da4e06ab48b36eb0a9b76d29bf1321fdf8b` |
| 951 | `IOSContextCompactionCoordinator.swift` | `4acfa4cffb463768fa5b7064f042cecddfaa2183ecc7dcd4b34f7e940491bb5b` |
| 1485 | `IOSConversationStore.swift` | `69c3bd1474d4512e60bb500103d7392d56ec88ff2ac6fd0a420cec781ceb7af6` |
| 1357 | `IOSSharedSettingsStore.swift` | `77cdcbcd8da9d6d9203b3fdc2f3e974d0ab7b44e7a882b7b5455e199ba87ae6c` |
| 1460 | `Infrastructure/Workspace/IOSWorkspaceStore.swift` | `88435574e9357a8c1cca6d7e6cd085d704da1823a8b85e5c265486292f167ef7` |
| 362 | `Settings/IOSSharedAgentFeatureSettings.swift` | `e644054a873560e937588e0b91d4dcea079c56d670d80618163af6a983ec3025` |
| 154 | `Settings/IOSSharedSettingsModels.swift` | `c381acde1304cf513c58b1f2356e792eb053c1f8cb0663473d58510a62935663` |

## Moved declarations and helpers

Each destination slice was compared character-for-character with the baseline slice, allowing only the visibility substitutions listed below. The JSON report lists every captured declaration signature and its original line.

### `DocumentAccessStore.swift:69-1525` → `Infrastructure/Workspace/IOSWorkspaceStore.swift:4-1460`

Original slice SHA-256: `e2ae1c926c594411c11d1edcb53894272069730b7294c821ddc3117c5e064bb4`. Destination slice SHA-256: `e2ae1c926c594411c11d1edcb53894272069730b7294c821ddc3117c5e064bb4`. Exact: `True`; declared visibility-normalized exact: `True`.

- 69: `enum IOSWorkspaceFileStatus`
- 77: `var title`
- 91: `enum IOSWorkspaceArtifactType`
- 100: `var id`
- 102: `var title`
- 117: `struct IOSWorkspaceFileRecord`
- 118: `let id`
- 119: `var displayName`
- 120: `var originalFileName`
- 121: `var workspacePath`
- 122: `var mimeType`
- 123: `var sizeBytes`
- 124: `var importedAtMillis`
- 125: `var updatedAtMillis`
- 126: `var status`
- 127: `var statusMessage`
- 128: `var preview`
- 129: `var isTruncated`
- 130: `var characterCount`
- 131: `var source`
- 133: `var byteSummary`
- 138: `struct IOSWorkspaceArtifactRecord`
- 139: `let id`
- 140: `var title`
- 141: `var type`
- 142: `var contentPath`
- 143: `var contentBytes`
- 144: `var summary`
- 145: `var createdAtMillis`
- 146: `var updatedAtMillis`
- 147: `var sourceKind`
- 148: `var sourceId`
- 151: `private struct IOSWorkspaceState`
- 152: `var files`
- 153: `var artifacts`
- 156: `enum IOSWorkspaceStoreError`
- 166: `var errorDescription`
- 188: `enum IOSWorkspaceToolCatalog`
- 189: `static let readToolNames`
- 190: `static let writeToolNames`
- 191: `static let supportedToolNames`
- 196: `final class IOSWorkspaceStore`
- 197: `static let shared`
- 204: `let maxImportBytes`
- 205: `let maxPreviewCharacters`
- 234: `var recentFiles`
- 238: `var recentArtifacts`
- 242: `func reload`
- 265: `func importFile`
- 331: `func reparseFile`
- 349: `func removeFile`
- 373: `func saveArtifact`
- 414: `func artifactContent`
- 421: `func deleteArtifact`
- 444: `func executeTool`
- 476: `func fileRecord`
- 487: `func fileURL`
- 491: `func amberShellRootEntries`
- 495: `func amberShellList`
- 515: `func amberShellReadText`
- 533: `func amberShellWriteText`
- 565: `func amberShellValidateWriteTarget`
- 574: `func amberShellPathIdentity`
- 580: `func amberShellCreateDirectory`
- 590: `func amberShellTouch`
- 623: `func amberShellCopy`
- 655: `func amberShellMove`
- 684: `func amberShellRemove`
- 709: `private func amberShellRelativePath`
- 750: `private func amberShellURL`
- 790: `private func amberShellRequireRegularFile`
- 803: `private func amberShellIsSymbolicLink`
- 813: `private func amberShellPreparedRecord`
- 840: `private func amberShellRequireUnchanged`
- 853: `private func commitFileRecord`
- 861: `private func rollbackPayload`
- 872: `private func restorePayload`
- 883: `private func workspaceFileReadJSON`
- 944: `private static func readWorkspaceFileLines`
- 1001: `private static func workspaceLineNumber`
- 1013: `private func workspaceFileWriteJSON`
- 1076: `private func workspaceFileEditJSON`
- 1165: `private static func workspaceEditDiffPreview`
- 1229: `private func workspaceFileListJSON`
- 1251: `private func workspaceFileSearchJSON`
- 1275: `private func workspaceFileMoveJSON`
- 1314: `private func workspaceArtifactReadJSON`
- 1331: `private func workspaceArtifactDeleteJSON`
- 1339: `private func parsedProposedRecord`
- 1351: `private func parsedRecord`
- 1394: `private func normalizeWorkspacePath`
- 1415: `private func fileURL`
- 1419: `private func startScopedAccessIfNeeded`
- 1428: `private func ensureDirectories`
- 1433: `private func persist`
- 1445: `private func publish`
- 1450: `private static func workspaceStatus`
- 1465: `private static func isInsideAppContainer`
- 1470: `private static func safeFileName`
- 1476: `private static func summary`
- 1484: `private static func millis`
- 1488: `private static func fileSize`
- 1496: `private static func jsonObject`
- 1504: `static func json`
- 1514: `private extension String`
- 1515: `var workspaceNilIfBlank`
- 1521: `private extension Comparable`
- 1522: `func workspaceClamped`

### `IOSContextCompactionCoordinator.swift:692-1164` → `Chat/Compaction/IOSContextCompactionBudget.swift:5-477`

Original slice SHA-256: `412491f0520fd3b49edd1c9eff0cb26834c09af3df506e9b2e4e0bbef59379f9`. Destination slice SHA-256: `412491f0520fd3b49edd1c9eff0cb26834c09af3df506e9b2e4e0bbef59379f9`. Exact: `True`; declared visibility-normalized exact: `True`.

- 692: `static let defaultContextWindowTokens`
- 693: `static let maxTimelineSummaryChars`
- 694: `static let maxHandoffChars`
- 695: `static let maxCompressionTextChars`
- 697: `static let compressionInputRatio`
- 699: `static func estimatePromptTokens`
- 703: `static func estimateTokens`
- 710: `static func nextTurnOccupancyTokens`
- 757: `static func estimatePreparedMessages`
- 774: `static func estimateDraftTokens`
- 780: `static func estimateContextWindow`
- 787: `static func planCompaction`
- 859: `static func planForceCompaction`
- 933: `static func prepareMessagesWithCompacts`
- 964: `static func fitMessagesToTokenBudget`
- 1021: `static func messageFittedToTokenBudget`
- 1041: `static func truncatingToolOutputs`
- 1068: `static func appendingTruncationNotice`
- 1081: `static func truncationNoticeText`
- 1085: `static func requestOverheadTokens`
- 1104: `static func assertFitsRequest`
- 1122: `static func trimmingCompactHandoffSystemMessages`
- 1140: `static func isCompactHandoffSystemMessage`
- 1146: `static func systemText`
- 1151: `static func compactHandoffText`

### `IOSContextCompactionCoordinator.swift:1165-1404` → `Chat/Compaction/IOSContextCompactionPreparedContext.swift:5-244`

Original slice SHA-256: `06abc5bbc960fcf9bb281cf8bebb8b29b1d88a9777d88e4a0615a83a1721eb27`. Destination slice SHA-256: `06abc5bbc960fcf9bb281cf8bebb8b29b1d88a9777d88e4a0615a83a1721eb27`. Exact: `True`; declared visibility-normalized exact: `True`.

- 1167: `static func editPreparedContext`
- 1189: `static func buildCompressionInput`
- 1201: `static func buildCompressionPrompt`
- 1243: `static func fillTemplate`
- 1258: `static func normalizedPayload`
- 1302: `static func isUsableHandoff`
- 1309: `static let handoffSectionNames`
- 1315: `static let compactionRetryPrompt`
- 1317: `static func injectionText`
- 1326: `static func injectionText`
- 1347: `static func compactedToolResultsNote`
- 1351: `static func timelineSummary`
- 1363: `static func selectCompactsForInjection`
- 1380: `static func validCompletedCompacts`

### `IOSContextCompactionCoordinator.swift:1406-1825` → `Chat/Compaction/IOSContextCompactionHandoffCodec.swift:4-423`

Original slice SHA-256: `4ba0573c0052ed34ed47f8fcfca80ec5c9a79c62332cf3605fe8faeecbefa7dc`. Destination slice SHA-256: `83e9c3f687f2dfc459c19288a08ec5ae1f61bf02d9e4c2e407555b018d35c7c7`. Exact: `False`; declared visibility-normalized exact: `True`.

- 1406: `private extension IOSContextCompactionCoordinator`
- 1407: `static let defaultHandoffPrompt`
- 1421: `static func skipped`
- 1433: `static func estimateAfterCompaction`
- 1452: `static func transitiveCompactIds`
- 1466: `static func transitiveCoveredIds`
- 1483: `static func estimatedChars`
- 1487: `static func summaryLine`
- 1512: `static func summarizeToolOutput`
- 1523: `static func editMessageTools`
- 1554: `static let compactedToolOutputMarker`
- 1556: `static func trimToolResult`
- 1573: `static func clearToolResult`
- 1591: `static func replacingToolOutput`
- 1599: `static func canEditPreparedResult`
- 1605: `static func safeToClearPreparedResult`
- 1611: `static let clearableToolNames`
- 1628: `static let sensitiveSessionTools`
- 1631: `private extension IOSContextCompactionCoordinator`
- 1632: `static func limitContext`
- 1666: `static func messageId`
- 1670: `static func messageHasExecutedTool`
- 1674: `static func messageHasPendingTool`
- 1678: `static func messageHasMultimodalPart`
- 1682: `static func partsContainMultimodal`
- 1695: `static func outputLooksFailedOrDenied`
- 1705: `static func outputChars`
- 1714: `static func intValue`
- 1718: `static func supportsTextGeneration`
- 1722: `static func nowMillis`
- 1727: `private extension IOSContextCompactionCoordinator`
- 1728: `static func parseJSONObject`
- 1737: `static func payloadObject`
- 1747: `static func locateJSONObject`
- 1779: `static func stringValue`
- 1789: `static func stringList`
- 1795: `static func jsonString`
- 1804: `static func cleanHumanText`
- 1813: `static func cleanMarkdown`
- 1817: `static func coerceTimelineSummary`

### `IOSConversationStore.swift:61-93` → `Chat/Storage/IOSConversationContentAccess.swift:4-36`

Original slice SHA-256: `65f62822d4ae10df1d19e8c7a51c051ae36c289c2752c8566f4bd86a7039b013`. Destination slice SHA-256: `65f62822d4ae10df1d19e8c7a51c051ae36c289c2752c8566f4bd86a7039b013`. Exact: `True`; declared visibility-normalized exact: `True`.

- 61: `struct IOSConversationSearchResult`
- 74: `let id`
- 75: `let conversationId`
- 76: `let kind`
- 77: `let title`
- 78: `let preview`
- 79: `let highlight`
- 80: `let updateAt`
- 86: `struct IOSSessionSearchHit`
- 87: `let conversationId`
- 88: `let title`
- 89: `let snippet`
- 90: `let updatedAt`
- 91: `let messageCount`

### `IOSConversationStore.swift:1193-1381` → `Chat/Storage/IOSConversationContentAccess.swift:38-226`

Original slice SHA-256: `70daccb1c08e5b9cde00e31964f9f244d634928b22a1b467d26a4ff4b45b96a7`. Destination slice SHA-256: `2edf1bb4f1e5f9d25283ff306ae5c853e60780795727ac27dcd2b8dc361644f0`. Exact: `False`; declared visibility-normalized exact: `True`.

- 1193: `func currentConversationDeepReadSource`
- 1209: `func appendDeepReadResultToCurrentConversation`
- 1231: `func searchConversations`
- 1282: `func sessionSearchHits`
- 1329: `func boardSignalCandidates`
- 1364: `private static func boardRoleName`
- 1372: `private static func searchableMessages`

### `IOSConversationStore.swift:1490-1506` → `Chat/Storage/IOSConversationContentAccess.swift:227-243`

Original slice SHA-256: `d2cd29eb613ab119e17f5faefec2177de55af243e37d75ce8f0b76c4097c0f2f`. Destination slice SHA-256: `d2cd29eb613ab119e17f5faefec2177de55af243e37d75ce8f0b76c4097c0f2f`. Exact: `True`; declared visibility-normalized exact: `True`.

- 1490: `private static func searchPreview`

### `IOSConversationStore.swift:1524-1798` → `Chat/Storage/IOSConversationBranching.swift:5-279`

Original slice SHA-256: `e1a6ac768cc84f57dbca5d90d8e34d38baa327492baaff97f8a6ebec1a8e4f31`. Destination slice SHA-256: `27dbf5865132100c50964a76fbf7f877d187bd11be22958d58738a20dc7d4461`. Exact: `False`; declared visibility-normalized exact: `True`.

- 1548: `func variantInfo`
- 1561: `private func conversationForMessageMutation`
- 1580: `func selectVariant`
- 1624: `func appendVariant`
- 1666: `func appendVariantAndTruncateAfter`
- 1715: `func deleteMessage`
- 1753: `func truncateAfter`
- 1783: `private func conversationWithNodes`

### `IOSSharedSettingsStore.swift:1330-1686` → `Settings/IOSSharedAgentFeatureSettings.swift:5-361`

Original slice SHA-256: `8045a4ecc61aa7e5a275e075e118e5d63ef2353ec5095ed09ffb7372f314fc10`. Destination slice SHA-256: `8045a4ecc61aa7e5a275e075e118e5d63ef2353ec5095ed09ffb7372f314fc10`. Exact: `True`; declared visibility-normalized exact: `True`.

- 1330: `var savedSubAgentOverrides`
- 1335: `var allowsDynamicSubAgents`
- 1339: `var subAgentMaxConcurrentRuns`
- 1343: `var subAgentTimeoutMinutes`
- 1347: `var subAgentModelPool`
- 1351: `func setDynamicSubAgentsAllowed`
- 1355: `func setSubAgentExecutionLimits`
- 1363: `func setSubAgentModelPool`
- 1370: `func setSubAgentPoolReasoning`
- 1378: `func configureSubAgentRole`
- 1401: `func resetSubAgentRole`
- 1406: `func subAgentReasoningLevels`
- 1415: `func addSubAgentOverride`
- 1434: `func removeSubAgentOverride`
- 1456: `var currentAssistantEnabledSkillNames`
- 1460: `func isSkillEnabled`
- 1464: `func setSkillEnabled`
- 1477: `func updateUserNickname`
- 1484: `var modeInjections`
- 1488: `func upsertModeInjection`
- 1496: `func deleteModeInjection`
- 1502: `var lorebooks`
- 1506: `func upsertLorebook`
- 1513: `func deleteLorebook`
- 1517: `func removeSkillFromAllAssistants`
- 1529: `func setMiniAppHostContextEnabled`
- 1539: `func setMiniAppHostWriteEnabled`
- 1549: `func updateMiniAppRuntime`
- 1577: `var todayBoard`
- 1581: `func updateTodayBoard`
- 1609: `var ttsProviders`
- 1614: `var selectedTTSProviderId`
- 1620: `var providers`
- 1627: `var chatModelIds`
- 1642: `var assistants`
- 1647: `var searchServices`
- 1652: `var searchServiceSelected`
- 1655: `var enableWebSearch`
- 1656: `var searchBuiltinJinaEnabled`
- 1657: `var searchBuiltinDuckDuckGoEnabled`
- 1658: `var searchBuiltinBingEnabled`
- 1659: `var searchBuiltinWikipediaEnabled`
- 1660: `var searchBuiltinHackerNewsEnabled`
- 1661: `var searchGoogleWebViewFallbackEnabled`
- 1664: `var searchResultSize`
- 1667: `var displaySetting`
- 1673: `var agentRuntime`
- 1682: `var imageGenerationModelId`
- 1683: `var titleModelId`
- 1684: `var suggestionModelId`
- 1685: `var ocrModelId`
- 1686: `var compressModelId`

### `IOSSharedSettingsStore.swift:1689-1839` → `Settings/IOSSharedSettingsModels.swift:4-154`

Original slice SHA-256: `913965ef47489a6e09f44fd33371e9606aa11f01c878d2e766a83ddc92f3e404`. Destination slice SHA-256: `913965ef47489a6e09f44fd33371e9606aa11f01c878d2e766a83ddc92f3e404`. Exact: `True`; declared visibility-normalized exact: `True`.

- 1689: `struct MiniAppSettingPatch`
- 1690: `var enabled`
- 1691: `var networkEnabled`
- 1692: `var externalImagesEnabled`
- 1693: `var searchEnabled`
- 1694: `var clipboardCopyEnabled`
- 1695: `var boardSummaryUpdateEnabled`
- 1696: `var hostContextEnabled`
- 1697: `var hostWriteEnabled`
- 1698: `var aiEnabled`
- 1699: `var sharedStoreEnabled`
- 1700: `var eventBusEnabled`
- 1701: `var launchEnabled`
- 1702: `var sensorEnabled`
- 1703: `var locationEnabled`
- 1704: `var clipboardReadEnabled`
- 1705: `var webViewDebugEnabled`
- 1706: `var showSourceButton`
- 1747: `struct TodayBoardSettingPatch`
- 1748: `var boardModelId`
- 1749: `var clearBoardModelId`
- 1750: `var hotListRefreshIntervalMinutes`
- 1751: `var hotListWifiOnly`
- 1752: `var hotListEnabledSources`
- 1753: `var hotListFocusKeywords`
- 1754: `var hotListFilterModeWireName`
- 1755: `var boardReadingFontModeWireName`
- 1756: `var boardReadingFontPackId`
- 1757: `var clearBoardReadingFontPackId`
- 1758: `var deepReadFontScale`
- 1759: `var deepReadTemplateId`
- 1760: `var hotListTranslateToChinese`
- 1793: `struct IOSRemoteSyncStatus`
- 1794: `var lastUploadAt`
- 1795: `var lastDownloadAt`
- 1796: `var remoteRevision`
- 1797: `var provider`
- 1798: `var providerRevisions`
- 1799: `var deviceLabel`
- 1800: `var lastBackupVersionName`
- 1801: `var lastBackupVersionCode`
- 1802: `var lastError`
- 1806: `func remoteRevision`
- 1810: `func scoped`

## Retained source and key body checks

- `DocumentAccessStore.swift`: baseline `c118aaecc6d55ae949a57c37f22062590a1ad9748b1a1f3fa04febef1073dd4a`; current `22a1315fadd42c164af1c230ce5d8da4e06ab48b36eb0a9b76d29bf1321fdf8b`; retained reconstruction exact after moved slices and listed visibility changes.
- `IOSContextCompactionCoordinator.swift`: baseline `78a6e2756025b2cacf554b1008996e400327a7c548cf698d69cbe41ef886f27d`; current `4acfa4cffb463768fa5b7064f042cecddfaa2183ecc7dcd4b34f7e940491bb5b`; retained reconstruction exact after moved slices and listed visibility changes.
- `IOSConversationStore.swift`: baseline `e4ba99aa338dc822b05a91ead7ae9dfc8526e33ce5e74b27332e82904118e952`; current `69c3bd1474d4512e60bb500103d7392d56ec88ff2ac6fd0a420cec781ceb7af6`; retained reconstruction exact after moved slices and listed visibility changes.
- `IOSSharedSettingsStore.swift`: baseline `51a5cfb039ce84d456b6d1e3a625c458d0addd00d7b64c43742aa2ce75431390`; current `77cdcbcd8da9d6d9203b3fdc2f3e974d0ab7b44e7a882b7b5455e199ba87ae6c`; retained reconstruction exact after moved slices and listed visibility changes.

- `DocumentAccessStore.swift:1645` → `DocumentAccessStore.swift:188` `consumeSelectedFileRead` inner body: `234b625311c8a0f3687c9daf9626aa3c28d8a2d581aaa31b86ad8c9523d25ede` (exact).
- `DocumentAccessStore.swift:1433` → `Infrastructure/Workspace/IOSWorkspaceStore.swift:1368` `persist` inner body: `b8f35fb2ea2d0f9b1fa94839bc5528f8c152f948aeefd7e2fd63b56221031bda` (exact).
- `IOSContextCompactionCoordinator.swift:364` → `IOSContextCompactionCoordinator.swift:364` `compactConversation` inner body: `c326189c1bceb97c88184531940c45af214d471ede453e7c93f3faff7692c7a3` (exact).
- `IOSContextCompactionCoordinator.swift:403` → `IOSContextCompactionCoordinator.swift:403` `compactConversationLocked` inner body: `f07b41e8ff25c5f1a3731a04b0ebc91680b8527de417b91c3427470a8bd2f33d` (exact).
- `IOSContextCompactionCoordinator.swift:574` → `IOSContextCompactionCoordinator.swift:574` `generateCompactSummary` inner body: `64222e830e9c7ea7a1da75419eba250925edf4c5b55db165236129766bf5620c` (exact).
- `IOSConversationStore.swift:1800` → `IOSConversationStore.swift:1286` `persist` inner body: `50965fca811160d211c8c547fd4308d546111c536f7ffb48235573d5dec67951` (exact).
- `IOSConversationStore.swift:1850` → `IOSConversationStore.swift:1336` `acceptsWrite` inner body: `0eb533cfacdcc0bb09bd93c4b5d07171136041acac5cd3dcdaa90085ad61c8ca` (exact).
- `IOSConversationStore.swift:1873` → `IOSConversationStore.swift:1359` `acceptsImportEpoch` inner body: `97bf162d9162d11d9f08cac3b5ec39913b93f75a69220beb94e2e305217fe72e` (exact).
- `IOSConversationStore.swift:1888` → `IOSConversationStore.swift:1374` `beginConversationWrite` inner body: `236b27bb7d0d0b5e28049b84b6f02f49259d110850af2e48e66bda942431d39f` (exact).
- `IOSConversationStore.swift:1899` → `IOSConversationStore.swift:1385` `finishConversationWrite` inner body: `9d794144ec1d9fb73fcde0953ccdf019371a63e0b94e3dafc6102aa44ebc7dc4` (exact).
- `IOSConversationStore.swift:1907` → `IOSConversationStore.swift:1393` `waitForConversationWritesToDrain` inner body: `53648b83f9bb502f033680df836ad6e60d4b60671ace295a3639a08c70cf5251` (exact).
- `IOSConversationStore.swift:1914` → `IOSConversationStore.swift:1400` `advanceWriteSequence` inner body: `b2fc6b3551ce168bf3a2ace289456a7cddb00525d47d639d066e96934bc8a5dc` (exact).
- `IOSSharedSettingsStore.swift:276` → `IOSSharedSettingsStore.swift:276` `restoreSnapshot` inner body: `5dddd6a571002cb718cbe001251377bc49eb0f1d2d68a3c3e394dee351c1b229` (exact).
- `IOSSharedSettingsStore.swift:322` → `IOSSharedSettingsStore.swift:322` `credentialValues` inner body: `92cf5d9f8749704a5c775f62f50442de84f94344f5d3315fece9f2170857b3b3` (exact).

## Visibility changes

- `DocumentAccessStore.swift`: `fileprivate extension DocumentAccessError {` → `extension DocumentAccessError {` — Workspace tool error handling uses the same user-visible message across files.
- `IOSContextCompactionCoordinator.swift`: `private struct IOSConversationCompact` → `struct IOSConversationCompact` — shared compact record across extracted helpers.
- `IOSContextCompactionCoordinator.swift`: `private struct IOSCompactPolicy` → `struct IOSCompactPolicy` — shared planner policy across extracted helpers.
- `IOSContextCompactionCoordinator.swift`: `private struct IOSCompactPlan` → `struct IOSCompactPlan` — shared plan result across extracted helpers.
- `IOSContextCompactionCoordinator.swift`: `private extension String {` → `extension String {` — token/text helper called across files.
- `IOSContextCompactionCoordinator.swift`: `private extension IOSCompactPolicy {` → `extension IOSCompactPolicy {` — six-field planner policy initializer called by budget extension.
- `IOSConversationStore.swift`: `private let storage: JsonConversationStorage` → `let storage: JsonConversationStorage` — search and branch extension reads canonical storage.
- `IOSConversationStore.swift`: `private var importEpoch: UInt64` → `private(set) var importEpoch: UInt64` — branch extension reads canonical restore epoch; only original owner may advance it.
- `IOSConversationStore.swift`: `private func publishIOError(` → `func publishIOError(` — branch extension reports canonical I/O error.
- `IOSConversationStore.swift`: `private func nowInstant()` → `func nowInstant()` — branch extension constructs mutated conversation.
- `IOSConversationStore.swift`: `private func setCurrent(` → `func setCurrent(` — branch extension uses canonical revision owner.
- `IOSConversationStore.swift`: `private func persist(` → `func persist(` — branch extension routes through canonical writer.
- `IOSConversationStore.swift`: `private func acceptsImportEpoch(` → `func acceptsImportEpoch(` — branch extension checks canonical restore gate.
- `IOSConversationStore.swift`: `private func refreshSummaries()` → `func refreshSummaries()` — branch extension refreshes canonical list.
- `IOSConversationStore.swift`: `private func visibleSummariesForListing()` → `func visibleSummariesForListing()` — search and Board extension use canonical visibility.
- `IOSConversationStore.swift`: `private func isDeletedConversation(` → `func isDeletedConversation(` — branch extension checks canonical tombstones.
- `IOSSharedSettingsStore.swift`: `private let defaults: UserDefaults` → `let defaults: UserDefaults` — agent feature extension reads canonical defaults.
- `IOSSharedSettingsStore.swift`: `private let subAgentOverridesKey =` → `let subAgentOverridesKey =` — agent feature extension uses the same persisted key.
- `Chat/Compaction/IOSContextCompactionBudget.swift`: `private extension IOSContextCompactionCoordinator` → `extension IOSContextCompactionCoordinator` — cross-file coordinator helpers.
- `Chat/Compaction/IOSContextCompactionPreparedContext.swift`: `private extension IOSContextCompactionCoordinator` → `extension IOSContextCompactionCoordinator` — cross-file coordinator helpers.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `private extension IOSContextCompactionCoordinator` → `extension IOSContextCompactionCoordinator` — message planning helpers used across files.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `private extension IOSContextCompactionCoordinator` → `extension IOSContextCompactionCoordinator` — message helpers used across files.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `private extension IOSContextCompactionCoordinator` → `extension IOSContextCompactionCoordinator` — handoff payload helpers used across files.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `static func messageHasExecutedTool(` → `private static func messageHasExecutedTool(` — keep codec-only helper private after extension visibility change.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `static func partsContainMultimodal(` → `private static func partsContainMultimodal(` — keep codec-only helper private after extension visibility change.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `static func outputLooksFailedOrDenied(` → `private static func outputLooksFailedOrDenied(` — keep codec-only helper private after extension visibility change.
- `Chat/Compaction/IOSContextCompactionHandoffCodec.swift`: `static func locateJSONObject(` → `private static func locateJSONObject(` — keep codec-only helper private after extension visibility change.
- `Chat/Storage/IOSConversationBranching.swift`: `private func conversationForMessageMutation(` → `func conversationForMessageMutation(` — original store calls branch mutation loader.
- `Chat/Storage/IOSConversationBranching.swift`: `private func conversationWithNodes(` → `func conversationWithNodes(` — original store calls branch node constructor.
- `Chat/Storage/IOSConversationContentAccess.swift`: `private static func searchableMessages(` → `static func searchableMessages(` — empty-conversation reuse in original owner calls this helper.

## Owner invariants

- Workspace records, index writes, rollback, and path identity remain on the same `IOSWorkspaceStore` instance and retain `AmberWorkspace/files`, `AmberWorkspace/artifacts`, and `AmberWorkspace/workspace.json`.
- Compaction task cancellation, cancellation check before save, and compact store writes remain in `IOSContextCompactionCoordinator.swift`; extracted helpers operate through the original coordinator type.
- Conversation `persist`, write sequences, import epoch, drain and deletion tombstones remain in `IOSConversationStore.swift`; branch mutations call those methods.
- Settings `restoreSnapshot` retains its credential write/rollback, masked JSON and in-memory snapshot commit, then obsolete credential deletion sequence.
- `HomeDesignContractTests` source guard at line 782 remains satisfied in the original Conversation source.

Syntax parse, length guard, and whitespace/diff checks were run separately; no build or tests were run by this worker.
