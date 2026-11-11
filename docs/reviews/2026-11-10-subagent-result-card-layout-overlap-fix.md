# Subagent Result Card Layout Overlap & Bottom Scroll Clipping Fix (2026-11-10)

## 1. Root Cause Analysis

### Symptom 1 & 2 Single Mechanism (`ChatTimelineRowLayout` + `ChatSubAgentResultCard`)
1. **Stale Row Height Cache on Expand (`ChatSubAgentResultCard.swift` / `ChatTimelineRowLayout.swift`)**:
   - `NativeTimelineMessageBubble` (`iosApp/iosApp/Chat/Timeline/ChatTimelineRows.swift:116-131`) wraps each message row in `ChatTimelineRowLayout(messageID: model.row.messageId, tracksRowInvalidation: true, layoutSignature: rowLayoutSignature)` and injects `.environment(\.markdownLayoutInvalidationID, model.row.messageId)`.
   - When `tracksRowInvalidation == true`, `ChatTimelineRowLayout` only clears `cache.sizes` / `cache.lastFiniteSize` when `ChatTimelineRowLayoutInvalidation.currentToken(for: messageID, layoutSignature: layoutSignature)` changes.
   - `ChatSubAgentResultCard` (`iosApp/iosApp/ChatSubAgentResultCard.swift`) previously neither read `@Environment(\.markdownLayoutInvalidationID)` nor called `ChatTimelineRowLayoutInvalidation.markRowDirty(layoutInvalidationID)` when `isExpanded` toggled (`false -> true` or `true -> false`). Because `isExpanded` is private `@State` inside `ChatSubAgentResultCard`, toggling it only re-evaluates `ChatSubAgentResultCard.body` (not `MessageBubbleStatefulContent.body`).
   - Additionally, `ChatTimelineRowLayout.sizeThatFits` did not synchronize `cache.invalidationToken` after measuring `row.sizeThatFits(measurementProposal)` or check for token changes when `sizeThatFits` ran ahead of `updateCache`.
   - As a result, once a turn settled (`.generationCompleted`), expanding a `ChatSubAgentResultCard` left `ChatTimelineRowLayout` returning the cached collapsed height (`44pt`) to `ChatTimelineChunkView` (`VStack`) and `UIScrollView`, while `ChatSubAgentResultCardLayout.placeSubviews` placed the expanded card body with `ProposedViewSize(width: bounds.width, height: nil)` (`824.17pt` in synthetic test):
     - **Symptom 1 (Bottom clipped behind composer / cannot scroll to bottom)**: `UIScrollView.contentSize.height` grew by `0pt` instead of `+780.17pt`, so the expanded card bottom (`maxY = 1630.17pt`) overflowed far past the maximum scrollable visible bottom above the composer (`874.5pt`).
     - **Symptom 2 (Second result card overlaps first expanded card)**: `ChatTimelineChunkView`'s `VStack` positioned the second `ChatSubAgentResultCard` at `card1.minY + 44pt + 14pt` (`minY = 864.0pt`), directly on top of the first card's expanded Markdown body (`maxY = 1630.17pt`).
2. **Outgoing `.transition(.opacity)` Body Holding Row Height Open on Collapse (`ChatSubAgentResultCard.swift`)**:
   - Inside `ChatSubAgentResultCard`, `header` and `if isExpanded { resultBody.transition(.opacity) }` were previously placed in a plain `VStack`. When collapsing with animation (`reduceMotion == false`, `.easeInOut(duration: 0.22)`), SwiftUI keeps the outgoing `resultBody` in the subview list during the 0.22s fade-out transition. Measuring the `VStack` at the start of the collapse transaction therefore still included `resultBody`'s full height (`824.17pt`) and cached it under the post-toggle invalidation token, leaving the row stuck at `824.17pt` after collapse completed.

## 2. Targeted Changes (`file:line`)

- [`iosApp/iosApp/ChatSubAgentResultCard.swift:18-92`](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosApp/ChatSubAgentResultCard.swift#L18-L92):
  - Added `@Environment(\.markdownLayoutInvalidationID) private var layoutInvalidationID`.
  - Called `ChatTimelineRowLayoutInvalidation.markRowDirty(layoutInvalidationID)` in `ChatSubAgentResultCard.body` and `toggleExpansion()`.
- [`iosApp/iosApp/ChatSubAgentResultCard.swift:214-281`](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosApp/ChatSubAgentResultCard.swift#L214-L281):
  - Replaced the inner `VStack` with `ChatSubAgentResultStackLayout(isExpanded: isExpanded)`, which measures only `header` when `isExpanded == false` so an outgoing `.transition(.opacity)` body fades inside the shrinking clipped card surface without holding the row height open.
- [`iosApp/iosApp/Chat/Timeline/ChatTimelineRowLayout.swift:122-167`](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosApp/Chat/Timeline/ChatTimelineRowLayout.swift#L122-L167):
  - Synchronized and checked `cache.invalidationToken` inside `ChatTimelineRowLayout.sizeThatFits` so token invalidations during child body evaluation always clear stale cached row measurements and record the current token when storing a newly measured size.
- [`iosApp/iosAppTests/ChatTimelineRowLayoutTests.swift:84-333`](file:///Users/arquiel/.synara/worktrees/ce201253131e/iosApp/iosAppTests/ChatTimelineRowLayoutTests.swift#L84-L333):
  - Added synthetic desensitized UIKit+SwiftUI timeline regression test `testSubAgentResultCardExpandCollapseAndConsecutiveArrivalMaintainNonOverlappingLayoutAndBottomScrollReachability`.

## 3. TDD Verification (RED -> GREEN)

### Command
```bash
xcodebuild test -quiet -jobs 2 -parallel-testing-enabled NO \
  -project iosApp/AmberAgent.xcodeproj -scheme iosApp \
  -destination 'platform=iOS Simulator,id=F3D5299E-EEA6-4098-BF61-AB1C516933C0' \
  -derivedDataPath /Users/arquiel/Library/Developer/Xcode/DerivedData/AmberAgent-gztviftspdepikbgojeuyltfvnsg \
  -only-testing:iosAppTests/ChatTimelineRowLayoutTests \
  -only-testing:iosAppTests/ChatTimelineReviewRegressionTests/testRowZeroOuterRefreshSkipsGraphHostAndRowRemeasureWhileStreamingLineWrapGrowsHeight \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testSubAgentResultCardHugsShortContentAndBoundsLongMarkdown \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testResultCardBoundsUnbrokenMarkdownAndAccessibilityNames \
  -only-testing:iosAppTests/ChatMessagePresentationTests/testResultCardStartsCollapsedAndLongResultsDoNotGrowTheRow \
  -only-testing:iosAppTests/PerformanceHygieneTests/testMessageBubbleViewInjectsIdentityStableEnvironmentValues
```

### RED Output (Before Fix)
- `XCTAssertEqualWithAccuracy failed: ("44.0") is not equal to ("824.1666666666666") +/- ("1.0") - 展开子代理结果卡后 ChatTimelineRowLayout 行高必须同步增长，不得停留在折叠高度 44pt` (`ChatTimelineRowLayoutTests.swift:221`)
- `XCTAssertEqualWithAccuracy failed: ("0.0") is not equal to ("780.1666666666666") +/- ("2.0") - UIScrollView.contentSize.height 必须包含展开后的完整增量高度` (`ChatTimelineRowLayoutTests.swift:228`)
- `XCTAssertLessThanOrEqual failed: ("1630.1666666666665") is greater than ("874.5") - 最后一张展开的结果卡底部必须能够滚到输入栏 (safeAreaInset.bottom) 之上，不得被遮挡` (`ChatTimelineRowLayoutTests.swift:235`)
- `XCTAssertGreaterThanOrEqual failed: ("864.0") is less than ("1643.6666666666665") - 后到达的第二张结果卡必须排布在第一张已展开结果卡底部之下，绝不能重叠压在第一张正文上` (`ChatTimelineRowLayoutTests.swift:257`)
- `XCTAssertGreaterThanOrEqual failed: ("864.0") is less than ("1643.6666666666665") - 连续两张展开的结果卡之间不得发生任何 frame 重叠` (`ChatTimelineRowLayoutTests.swift:279`)
- `XCTAssertEqualWithAccuracy failed: ("824.1666666666666") is not equal to ("44.0") +/- ("1.0") - 收起第一张结果卡后 ChatTimelineRowLayout 行高必须回落到 44pt` (`ChatTimelineRowLayoutTests.swift:326`)

### GREEN Output (After Fix)
- `7/7` targeted tests passed (`exit 0`), including `ChatTimelineRowLayoutTests` (`2/2`), `ChatTimelineReviewRegressionTests/testRowZeroOuterRefreshSkipsGraphHostAndRowRemeasureWhileStreamingLineWrapGrowsHeight` (`1/1`), `ChatMessagePresentationTests` (`3/3`), and `PerformanceHygieneTests` (`1/1`).
