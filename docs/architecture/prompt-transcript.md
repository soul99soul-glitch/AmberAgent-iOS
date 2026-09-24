# Prompt and tool transitions

Amber records the initial prompt sections and tool declarations on the assistant response that consumed them. Later responses carry only changed sections, added declarations and removed tool names. The record is an opaque JSON string in `UIMessagePart.metadata.amber_prompt_transition_v1`; it adds no visible message and contains no executable closures, provider credentials, custom request headers or custom request bodies. Prompt text (including recalled memory and skills) and schemas are therefore part of the conversation's existing storage/export boundary.

`PromptTranscript.prepare` rebuilds request-only system messages from the selected canonical branch. Unchanged state creates no event. Compaction folds covered events into a leading checkpoint and keeps retained transitions before their corresponding assistant responses. Legacy/partial transcripts without a baseline start from the current prompt. Tool outputs, approval completion and background response completion must preserve the response metadata.

The current execution catalog remains authoritative. Persisted tool declarations do not grant execution permission. Native tool-addition endpoints restore loaded names across user turns against the current filtered registry, without restoring old schemas or executors. Provider adapters reconcile declarations with the current request tools before serialization.

Swift must use the Kotlin `copyTool` and `copyText` helpers when rewriting parts with metadata. Passing `part.metadata` back into a Swift initializer converts `JsonObject` to `NSDictionary`, which can crash later Kotlin access. They are exported to Swift as `doCopyTool` and `doCopyText`. The helpers keep the actual JSON object in Kotlin through approval, tool-result reconciliation, projection and citation stripping.

## Enabled transports

The capability table in `ai-core/PromptTranscript.kt` requires both an exact endpoint and a known model ID. API compatibility, a provider brand or a similar model name is insufficient.

| Transport | Instructions | Tools |
| --- | --- | --- |
| Official OpenAI Responses, GPT-5.4/mini/pro, GPT-5.5, GPT-5.6 Luna/Sol/Terra, GPT-6 Astra | Initial `instructions`, later inline system/developer messages | Initial top-level tools, later `additional_tools` |
| Codex Responses, same listed models | Same instruction placement | GPT-5.4 variants and GPT-5.5 use completed client tool-search replay; GPT-5.6 variants and GPT-6 Astra use `additional_tools` |
| Moonshot K3, official `.ai`/`.cn` endpoints | Inline system updates | Separate system messages containing only new complete tool definitions |
| Moonshot K2.6/K2.7 Code variants; official DeepSeek V4 Pro | Inline system updates | Complete current request-level tool list |
| Official Anthropic Opus 4.8/5, Fable 5/5.1 | System updates at assistant boundaries | Deferred declarations, stable placeholder, `tool_addition`/`tool_removal` beta |
| Other models and endpoints | Existing complete-current-prompt behavior | Complete current tool list |

Responses and Kimi fall back to the complete current tool list after removal or redeclaration. Anthropic keeps removed definitions declared and uses removal blocks; a schema replacement or an empty initial tool set uses the complete current tool list. Native tool transitions also respect the model's existing TOOL ability gates.

The host budgets transition text before compaction and validates the final expanded request without moving system events. Reaching a context limit, editing old messages, switching providers/models, changing reasoning options or using custom-body overrides can still invalidate a cache. No cache warming requests or new dependencies are introduced.

## Verification

Payload tests cover native instruction/tool placement, tool-only updates, deletion/replacement fallback, disabled tool ability and unknown endpoints. Core tests cover JSON restoration, branch isolation, compaction checkpoints, background handoff reconstruction and memory citation metadata. Swift engine tests exercise metadata persistence through actual tool loops and approval handling.

These tests establish request structure and local behavior. They do not prove service-side cache hits. For a live evaluation, use the same endpoint/model and conversation, warm a sufficiently large prefix, then change one prompt section, add a tool, remove a tool and replace a schema. Compare the existing `TokenUsage.cachedTokens` and time to first token against an unchanged control request. Record misses as well as hits; never infer caching merely from a stable prompt digest.

Local verification on 2026-09-20 used the Gradle-provisioned JDK, Xcode 27 and an iOS 26.5 iPhone 17 Pro simulator. The 265 JVM tests in ai-core, both provider modules, conversation storage and tools passed; Shared framework linking and the export-reachability check passed. The final main Swift batch passed 157 tests, including the two regression cases that originally exposed the metadata bridge crash. Its one additional scrolling timing case failed. A supplementary batch passed all 44 tests covering those two crash regressions again, Jev context projection, tool runtime and WebMount output budgets (`TEST SUCCEEDED`).

Two broader regression findings remain outside this change:

- `ChatSwiftUIStreamReplayTests.testLongProseViewportFollowStaysLineSizedAtTwentyFourKB` misses publication-count/cadence thresholds, including when run alone. The scrolling implementation and thresholds were not changed.
- `ChatViewModelSelectedFileContextTests.testAdvancedToolDeclarationsFollowParityRules` expects `subagent_dispatch` in the default exposed set. The current default registration uses the newer orchestration tools. Its assertions and registration policy were left unchanged; the case was excluded from subsequent targeted batches after recording the failure.

Live provider cache rates and physical-device behavior were not measured.

References: [Pi 0.86.0 implementation](https://github.com/earendil-works/pi/pull/9548), [OpenAI tool search and additional tools](https://developers.openai.com/api/docs/guides/tools-tool-search), [Anthropic mid-conversation changes](https://platform.claude.com/docs/en/build-with-claude/mid-conversation-system-messages), [Kimi dynamic tool loading](https://platform.kimi.ai/docs/guide/use-dynamic-tool-loading).
