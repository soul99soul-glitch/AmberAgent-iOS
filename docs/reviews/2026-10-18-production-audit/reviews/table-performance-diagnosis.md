# Table streaming performance diagnosis — 2026-10-18

Scope: the existing Native long-table streaming fixture and its production TableView path. Read-only diagnosis; this note does not establish a new product defect or claim to explain all frame time. No build, test, device operation or production edit was performed by this diagnosis task.

## Measurements and limits

- Earlier unprofiled fixture runs reported p95 35.57 ms (pass), 43.81 ms (full suite fail) and 41.38 ms (cold-process isolated fail), against the unchanged 40 ms threshold. These do not by themselves distinguish existing layout cost, the current repairs, or host variation.
- `table-profile-before-time-profile.xml`: 979 ms of main-thread running samples, trace sample range 0.515–2.695 seconds. TableLayout.makeCache had 58 ms inclusive, 31 ms through the default updateCache path and 27 ms under layout-engine initialization. Sampling did not establish repeated unchanged-content measurements or align these costs to the 80-to-92-row acceptance window. Counting all 58 ms as avoidable is unsupported.
- `table-profile-window-time-profile.xml`: filtered to main-thread stacks containing the actual `testPerfGrowingTableStreamingKeepsDisplayLinkResponsive` method, 1028 ms in 1028 samples, trace sample range 0.498–2.844 seconds. This includes work while that method is executing, including setup/warmup; it is not an explicit signpost of only the DisplayLink acceptance interval.
- In that filtered Perf segment, TableLayout.makeCache is 26 ms (2.53%); 24 ms includes LayoutSubview.sizeThatFits. All makeCache samples there go through the existing default updateCache path. TableCellTextView.body was not sampled in this segment; initializeWithCopy for that type had 1 ms.
- The instrumented p95 around 95 ms is diagnostic only, not acceptance evidence. Both captures used the same pre-experiment implementation; they are not a controlled code-before/code-after comparison.
- Inclusive symbol costs overlap. In particular, nested getter/policy costs must not be added to gridCellViewFor as independent savings. CPU sample milliseconds do not equal wall-clock frame gaps.

## Three requested costs in the filtered Perf segment

| Symbol | Inclusive ms | Perf main % |
| --- | ---: | ---: |
| TableView.gridCellViewFor(rowIdx:colIdx:) | 18 | 1.75% |
| TableView.config.getter | 5 | 0.49% |
| TableView.shouldAnimateTableText(_:) | 3 | 0.29% |

Reading a snapshot of style/padding/animation values once would be a plausible small independent experiment, and the unused characters.count policy argument is visible source work. These samples do not justify stacking that change onto the measurement-dedup experiment. The root has selected only the latter, so evidence remains attributable.

## Why choose a local measurement-dedup experiment

TableLayout.makeCache currently asks every cell twice: once unconstrained to resolve column widths, then at the final column width to resolve row heights. The initial 80 body rows plus header mean 486 sizeThatFits calls per full makeCache. The fixture's body has roughly 82 distinct full text values across 240 body cells (80 sequence numbers, one repeated long description, one repeated status), so many proposals repeat the same semantic work.

The smallest candidate is to attach complete AttributedString values to plain-text body subviews with a private LayoutValueKey, and deduplicate only within a single makeCache invocation: full attributed content for the unconstrained pass, content plus proposal width for the constrained pass. Header and attachment cells keep the old measurement path. New local dictionaries are discarded after makeCache. There is no cross-update cache, append state, Equatable cell boundary, attachment revision protocol, or guessed environment invalidation.

The current body cells share padding, line spacing, text environment and regular-cell styling in one layout invocation. Their position strings and border overlays do not change measured geometry. Layer animation uses the same final Text for layout; the existing animation-completion geometry test constrains that behavior. Within-pass reuse therefore has a small and directly inspectable contract. Complete attributed values retain font and inline-format distinctions; equal string lengths are insufficient.

SwiftUI may already reuse lower-level text layout, and attributed hashing has its own cost. With makeCache at only 2.53% of these samples, neither a material p95 improvement nor the 40 ms gate passing is guaranteed. Keep the experiment only if focused before/after measurement shows actual improvement without geometry or animation regressions. A failed experiment should be removed rather than followed by speculative caches.

## Alternatives deliberately not combined

- Explicit Equatable cells: four pure input comparisons can be behaviorally reasonable, and A11y outside the boundary would still update. But the trace did not show repeated TableCellTextView.body cost. Runtime conformance and AttributeGraph dirty propagation are not attributable to those cells from this capture. Equatable would also leave gridCellViewFor, config reads, the policy call and outer layout work in place.
- Cross-update geometry cache: stronger direct relation to makeCache, but needs content/attribute, width, padding, inherited lineSpacing and relevant font-environment invalidation, plus a decision for mutable attachments. The current sample does not establish how much same-content repeated measurement it could remove.
- Cross-update append measurement reuse: can store per-cell full content and ideal width plus old column widths/row heights, remeasure changed cells, recompute maxima, and remeasure all heights when final column widths change. This is a larger contract than the chosen single-call experiment and is not part of the chosen experiment.

## Actual font and geometry inputs

The production ChatAssistantText wrapper applies font and lineSpacing(4 * boundedScale). Inherited lineSpacing is a real separate geometry input. App table conversion writes explicit UIFont face/pointSize/traits into attributed content; chatFont, fontScale and ScaledMetric changes therefore change the attributed values. Copying the entire MarkdownRenderConfig or font library into a cache key would duplicate those facts and can include unstable color identity. Direct vendor users can supply text without explicit fonts, so a cross-update cache for the whole library would additionally need the actual fallback font/Dynamic Type contract. The chosen within-makeCache lifetime avoids maintaining that contract across updates.

## Regression entry points

- ChatStreamingTableLayoutTests.testGrowingTableDoesNotShrinkOrReplaceDisplayedTable exercises the live vendor renderer, character growth, identity and non-shrinking geometry, but alone cannot reject a stale height that simply stays constant.
- ChatStreamingTableLayoutTests.testTableMeasureCacheMatchesFullMeasureRowByRow compares incremental and fresh geometry for the static AmberMarkdownView, not the vendor path. Its fresh-versus-updated comparison is a useful pattern, not existing vendor coverage.
- ChatNativeTimelineReplayCompletionTests.testStreamingTableTailRowVisibleBeforeCompletionWithoutRelayout guards Native streaming-to-completion identity and height continuity.
- ChatNativeTimelineReplayPerformanceTests.testLayerBackedTableEntranceDoesNotChangeLayoutWhenAnimationCompletes guards the geometry equivalence of the animation overlay and final Text.
- Keep the original Native performance fixture and its thresholds. Relevant real geometry checks must accompany any kept experiment. Existing source-existence and parser-only tests cannot stand in for layout behavior.

## Filtered Perf top 20 production first-party inclusive symbols

Frames are classified by the `iosApp.debug.dylib` binary. Startup scaffolding `AmberAgentApp.$main` and `__debug_main_executable_dylib_entry_point` each have 1015 ms inclusive and are omitted from this useful-work list. Generic thunk expansion is retained verbatim below. These rows overlap.

| Inclusive ms | Perf main % | Symbol |
| ---: | ---: | --- |
| 27 | 2.63% | `protocol witness for Layout.updateCache(_:subviews:) in conformance TableLayout` |
| 26 | 2.53% | `TableLayout.makeCache(subviews:)` |
| 26 | 2.53% | `protocol witness for Layout.makeCache(subviews:) in conformance TableLayout` |
| 19 | 1.85% | `protocol witness for Layout.explicitAlignment(of:in:proposal:subviews:cache:) in conformance TableLayout` |
| 18 | 1.75% | `TableView.gridCellViewFor(rowIdx:colIdx:)` |
| 18 | 1.75% | `closure #1 in closure #2 in closure #1 in closure #1 in TableView.gridView.getter` |
| 15 | 1.46% | `closure #1 in MessageBubbleView.messagePartRows.getter` |
| 15 | 1.46% | `thunk for @escaping @callee_guaranteed (@unowned Int, @guaranteed SharedUIMessagePart) -> (@out _ConditionalContent<_ConditionalContent<_ConditionalContent<_ConditionalContent<_ConditionalContent<<<opaque return type of View.contextMenu<A>(menuItems:)>>.0, ModifiedContent<ChatMiniAppStreamingCard, _TraitWritingModifier<TransitionTraitKey>>>, <<opaque return type of View.chatLiveEntrance(key:isLive:)>>.0>, (<<opaque return type of View.chatLiveEntrance(key:isLive:)>>.0)?>, _ConditionalContent<ModifiedContent<ChatMediaGallery, _FlexFrameLayout>?, ChatVideoCard>>, _ConditionalContent<IOSMiniAppChatCard, TupleView<(<<opaque return type of View.chatLiveEntrance(key:isLive:)>>.0, _ConditionalContent<TupleView<(EquatableView<ChatToolMediaGallery>, ForEach<[(offset: Int, element: SharedUIMessagePart)], Int, ChatVideoCard?>)>, _ConditionalContent<_ConditionalContent<ModifiedContent<<<opaque return type of View.accessibilityFocused<A>(_:equals:)>>.0, _TraitWritingModifier<TransitionTraitKey>>, ModifiedContent<<<opaque return type of View.accessibilityFocused<A>(_:equals:)>>.0, _TraitWritingModifier<TransitionTraitKey>>>, ModifiedContent<<<opaque return type of View.accessibilityFocused<A>(_:equals:)>>.0, _TraitWritingModifier<TransitionTraitKey>>>>)>>>?)` |
| 13 | 1.26% | `MessageBubbleView.body.getter` |
| 13 | 1.26% | `closure #2 in closure #1 in closure #1 in closure #4 in NativeChatTimelineView.body.getter` |
| 13 | 1.26% | `partial apply for closure #2 in closure #1 in closure #1 in closure #4 in NativeChatTimelineView.body.getter` |
| 13 | 1.26% | `protocol witness for View.body.getter in conformance MessageBubbleView` |
| 11 | 1.07% | `Group.init(content:)` |
| 11 | 1.07% | `NativeChatTimelineView.entryView(_:displaySettingSignature:generativeUiSettingSignature:)` |
| 11 | 1.07% | `static IOSMiniAppChatMessageFactory.mightContainMiniApp(_:)` |
| 10 | 0.97% | `closure #1 in MessageBubbleView.body.getter` |
| 8 | 0.78% | `ChatAssistantStack.init(content:)` |
| 8 | 0.78% | `closure #2 in closure #1 in MessageBubbleView.body.getter` |
| 7 | 0.68% | `MessageBubbleView.messagePartRows.getter` |
| 7 | 0.68% | `MessageBubbleView.messageParts.getter` |

## Main-thread self samples for context

| Self ms | Perf main % | Symbol |
| ---: | ---: | --- |
| 61 | 5.93% | `AG::Graph::propagate_dirty(AG::AttributeID)` |
| 54 | 5.25% | `AG::Graph::UpdateStack::update()` |
| 51 | 4.96% | `<deduplicated_symbol>` |
| 33 | 3.21% | `AG::Subgraph::update(unsigned int)` |
| 26 | 2.53% | `find1<A>(_:key:filter:)` |
| 23 | 2.24% | `swift::MetadataCacheKey::operator==(swift::MetadataCacheKey const&) const` |
| 17 | 1.65% | `_platform_memmove` |
| 17 | 1.65% | `swift_conformsToProtocolMaybeInstantiateSuperclasses(swift::TargetMetadata<swift::InProcess> const*, swift::TargetProtocolDescriptor<swift::InProcess> const*, bool)::$_2::operator()((anonymous namespace)::ConformanceSection const&) const::'lambda'(swift::TargetProtocolConformanceDescriptor<swift::InProcess> const&)::operator()(swift::TargetProtocolConformanceDescriptor<swift::InProcess> const&) const` |
| 14 | 1.36% | `AG::Graph::UpdateStack::push(AG::data::ptr<AG::Node>, AG::Node&, bool, bool)` |
| 14 | 1.36% | `swift_release` |
| 13 | 1.26% | `__workq_kernreturn` |
| 12 | 1.17% | `_xzm_free` |

These broader SwiftUI/runtime costs are observations, not additional bug findings or evidence that the local table experiment will remove them.

## Artifacts

- `/tmp/amber-audit-20261018-current/table-profile-before-time-profile.xml`; SHA256 `39f21b662279642afd1abe758f2fbe521794cbf2758c5604205da94dfd7c74a0`
- `/tmp/amber-audit-20261018-current/table-profile-window-time-profile.xml`; SHA256 `2bf4c1d3a6df420d86c2c2d2767038fd08f98c98b5af0223055ed8a6a0f01d35`

Relevant nested rules were read from iosApp/vendor/SwiftStreamingMarkdown/AGENTS.md; no deeper AGENTS.md was found in that vendor subtree. The root owns build/test execution and the implementation decision.
