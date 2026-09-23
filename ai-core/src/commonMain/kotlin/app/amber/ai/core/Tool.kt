package app.amber.ai.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import app.amber.ai.provider.Model
import app.amber.ai.ui.UIMessage
import app.amber.ai.ui.UIMessagePart

@Serializable
data class Tool(
    val name: String,
    val description: String,
    val parameters: () -> InputSchema? = { null },
    val systemPrompt: (model: Model, messages: List<UIMessage>) -> String = { _, _ -> "" },
    val needsApproval: Boolean = false,
    val allowsAutoApproval: Boolean = true,
    // When true, this tool bypasses ordinary auto-approval, prior in-run trust,
    // and category fast-paths. Only the explicit "auto approve high-risk tools"
    // setting may run it unattended. Used for tools whose blast radius deserves
    // a stronger gate by default (e.g. wm_eval — arbitrary JS in a logged-in
    // WebView). See PermissionDecisionResolver for enforcement.
    val mandatoryApproval: Boolean = false,
    val execute: suspend (JsonElement) -> List<UIMessagePart>
)

fun createSearchWebToolDeclaration(): Tool = Tool(
    name = "search_web",
    description = """
        Search the web through AmberAgent iOS search execution.
        Use this when the user asks for latest news, current facts, or needs verification.
        Provide focused keywords in `query`; for news/current events, set `topic` and `time_range` when useful.
    """.trimIndent(),
    parameters = { searchWebParameters() },
    execute = { emptyList() }
)

fun createScrapeWebToolDeclaration(): Tool = Tool(
    name = "scrape_web",
    description = """
        Fetch a public http/https URL and extract readable page text through AmberAgent iOS search execution.
        Use this when search snippets are not enough or when the user asks about a specific page.
        iOS blocks local/private URLs and returns an honest error when content cannot be safely fetched.
    """.trimIndent(),
    parameters = { scrapeWebParameters() },
    execute = { emptyList() }
)

fun createAskUserToolDeclaration(): Tool = Tool(
    name = "ask_user",
    description = """
        Pause the current discussion and ask the user one focused question.
        Use only when the answer materially changes the advice. Provide concise options when useful;
        use an empty options array when the user should answer freely. Never call this with another tool.
    """.trimIndent().replace("\n", " "),
    parameters = { askUserParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

// MARK: - Novel discussion project tools
//
// Novel-session-only tools. They are declared here but deliberately NOT
// registered in the `iosToolDeclaration` catalog or ToolSearch: the discussion
// agent assembles them only inside the novel discussion transport
// (`NovelLiveModelAdapter.makeParameters`), so they never leak into ordinary
// Chat/subagent tool sets. Execution lives in `IOSNovelProjectToolExecutor`,
// which routes every mutation through `DefaultNovelCreation.perform` (the
// single reducer transaction path). `novel_revise_chapter` is approval-gated:
// the host shows an approval card and writes only after the author confirms.

fun createNovelRenameProjectToolDeclaration(): Tool = Tool(
    name = "novel_rename_project",
    description = """
        Rename the user's novel project. Use when the user asks to change the project title.
        `title` is the new project name; `reason` is an optional short note for the rename.
        The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { novelRenameProjectParameters() },
    execute = { emptyList() }
)

fun createNovelSetPolishPreferenceToolDeclaration(): Tool = Tool(
    name = "novel_set_polish_preference",
    description = """
        Set the novel project's polish preference (style requirements applied when polishing chapters).
        Pass an empty `preference` string to clear the stored preference.
        The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { novelSetPolishPreferenceParameters() },
    execute = { emptyList() }
)

fun createNovelUpsertUpcomingArcToolDeclaration(): Tool = Tool(
    name = "novel_upsert_upcoming_arc",
    description = """
        Save the branch's upcoming-arc notes ("往后几章") as a bounded soft direction.
        `beats` is a list of short beat notes: at most 8 beats, each at most 160 characters;
        longer or extra beats are rejected. Replaces any previously saved arc on this branch.
        The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { novelUpsertUpcomingArcParameters() },
    execute = { emptyList() }
)

fun createNovelClearUpcomingArcToolDeclaration(): Tool = Tool(
    name = "novel_clear_upcoming_arc",
    description = """
        Clear the branch's upcoming-arc notes ("往后几章") on the user's novel project.
        Takes no arguments. Fails if the branch has no arc notes to clear.
        The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createNovelReviseMaterialToolDeclaration(): Tool = Tool(
    name = "novel_revise_material",
    description = """
        Create or update a setting material (设定资料) in the user's novel project.
        With `material_id`, update that existing material (its `kind` must match); without it, create a new material.
        `kind` is one of world/character/relationship/masterOutline/writingRequirements/custom;
        `aliases` only applies to character materials; `custom_name` names a new custom card
        (default「自定义」). When the user's intent is ambiguous,
        ask the user first (ask_user) before writing. The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { novelReviseMaterialParameters() },
    execute = { emptyList() }
)

fun createNovelProposeChapterPlanToolDeclaration(): Tool = Tool(
    name = "novel_propose_chapter_plan",
    description = """
        Save a DRAFT chapter plan for the current branch of the user's novel project.
        The plan is always stored as a draft and must be manually confirmed by the user in the
        project control panel before ghostwrite can use it; never present it as already confirmed.
        `must_happen`/`must_not_happen`/`visible_facts` may be empty arrays; `goal_and_conflict` is required.
        The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { novelProposeChapterPlanParameters() },
    execute = { emptyList() }
)

fun createNovelPrepareGhostwriteToolDeclaration(): Tool = Tool(
    name = "novel_prepare_ghostwrite",
    description = """
        Prepare the agreed chapter plan and upcoming-arc reference for ghostwriting. Use this only
        after the discussion has reached a concrete direction and the author is ready to review it.
        The host shows an approval card with the full plan and a 1-10 chapter selector; nothing is
        written and ghostwriting does not start until the author approves. Do not use ask_user to
        ask whether to start after calling this tool. `must_happen` must be non-empty;
        `upcoming_arc` may be empty when the discussion has no reliable later-chapter direction.
    """.trimIndent(),
    parameters = { novelPrepareGhostwriteParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createNovelSetChapterTitleToolDeclaration(): Tool = Tool(
    name = "novel_set_chapter_title",
    description = """
        Rename one working manuscript chapter's title without rewriting the chapter body.
        `title` is the new chapter title (prefer a concise 1–8 character evocative title in the
        user's language). Target the chapter with optional `chapter_ordinal` (1-based index in the
        working manuscript order) or `chapter_id` (UUID); when both are omitted, the last (latest)
        working chapter is renamed. Does not edit prose content. Creates a manual-edit version and
        may mark the branch as needing plot-state sync. The change is saved into the novel project
        document.
    """.trimIndent(),
    parameters = { novelSetChapterTitleParameters() },
    execute = { emptyList() }
)

fun createNovelListChaptersToolDeclaration(): Tool = Tool(
    name = "novel_list_chapters",
    description = """
        List working manuscript chapters on the current branch (ordinal, title, character count,
        paragraph count, chapter_id). Discarded chapters are omitted. Use this before reading or
        revising a chapter that is not the latest one. This is read-only and does not change the
        project.
    """.trimIndent(),
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createNovelReadChapterToolDeclaration(): Tool = Tool(
    name = "novel_read_chapter",
    description = """
        Read one working manuscript chapter as numbered paragraphs. Target with optional
        `chapter_ordinal` (1-based working order) or `chapter_id` (UUID); when both are omitted,
        the latest working chapter is read. Optional `start_paragraph` and `end_paragraph` are
        1-based inclusive paragraph numbers from this tool's numbering. Use this when the injected
        manuscript tail is not enough (earlier chapters, earlier paragraphs, or exact paragraph
        numbers for novel_revise_chapter). This is read-only and does not change the project.
    """.trimIndent(),
    parameters = { novelReadChapterParameters() },
    execute = { emptyList() }
)

fun createNovelReviseChapterToolDeclaration(): Tool = Tool(
    name = "novel_revise_chapter",
    description = """
        Propose a paragraph-range replacement in an already collected working chapter. The host
        shows an approval card with the old and new text; the manuscript is written only after
        the author approves. `start_paragraph` and `end_paragraph` are 1-based inclusive indexes
        from novel_read_chapter. `new_text` replaces that range (it may be one or more paragraphs).
        Target with optional `chapter_ordinal` or `chapter_id`; omit both to revise the latest
        chapter. `reason` is an optional short note shown on the card. Never claim you cannot
        edit collected manuscript — call this after the author agrees on the change. Do not use
        ask_user to ask whether to apply. Creates a manual-edit version and marks the branch as
        needing plot-state sync when approved.
    """.trimIndent(),
    parameters = { novelReviseChapterParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createNovelRevertRecentChaptersToolDeclaration(): Tool = Tool(
    name = "novel_revert_recent_chapters",
    description = """
        Propose rolling back the last N working manuscript chapters together with their plot-state
        snapshots. The host shows an approval card listing the chapter titles; the branch head
        moves only after the author approves. `chapter_count` is the number of most recent
        non-discarded working chapters to revert (suffix only, not a middle-chapter delete).
        `reason` is an optional short note shown on the card. Refused while ghostwriting is
        advancing, if the working manuscript still needs sync, or if revert would pass the
        branch fork/initial boundary. Do not use ask_user to ask whether to apply.
    """.trimIndent(),
    parameters = { novelRevertRecentChaptersParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createNovelDeleteChaptersToolDeclaration(): Tool = Tool(
    name = "novel_delete_chapters",
    description = """
        Propose removing specific working manuscript chapters from the current branch directory,
        including middle chapters. The host shows an approval card listing the titles; chapters
        are removed only after the author approves. Provide `chapter_ordinals` (1-based working
        order) and/or `chapter_ids`. This is not a suffix rewind: plot-state snapshots stay,
        the branch is marked needsSync, and later chapter plots become unresolved until sync.
        Use novel_revert_recent_chapters only when the latest N chapters and their plot
        snapshots should roll back together. `reason` is an optional short note shown on the
        card. Refused while ghostwriting is advancing. Do not use ask_user to ask whether to
        apply.
    """.trimIndent(),
    parameters = { novelDeleteChaptersParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createNovelListSettingProposalsToolDeclaration(): Tool = Tool(
    name = "novel_list_setting_proposals",
    description = """
        List pending setting proposals on the current branch (id, title, content preview).
        These are uncommitted suggestions from plot-state sync, not saved materials.
        Use this to decide what to keep via novel_revise_material, then clear the rest with
        novel_reject_setting_proposals. This is read-only and does not change the project.
    """.trimIndent(),
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createNovelWorkspaceListToolDeclaration(): Tool = Tool(
    name = "novel_workspace_list",
    description = """
        List files in the novel workspace tree (chapters, setting, plot, plan, inbox, drafts).
        Optional `prefix` limits to a subdirectory such as setting/characters or branches.
        This is read-only and does not change the project.
    """.trimIndent(),
    parameters = { novelWorkspacePrefixParameters() },
    execute = { emptyList() }
)

fun createNovelWorkspaceReadToolDeclaration(): Tool = Tool(
    name = "novel_workspace_read",
    description = """
        Read one workspace file by path from novel_workspace_list.
        Use this instead of inventing new novel_* verbs when you need the file contents.
        This is read-only and does not change the project.
    """.trimIndent(),
    parameters = { novelWorkspacePathParameters() },
    execute = { emptyList() }
)

fun createNovelWorkspaceGrepToolDeclaration(): Tool = Tool(
    name = "novel_workspace_grep",
    description = """
        Search workspace files for a literal or simple substring `query`.
        Optional `prefix` limits the search. Returns matching paths and a short excerpt.
        This is read-only and does not change the project.
    """.trimIndent(),
    parameters = { novelWorkspaceGrepParameters() },
    execute = { emptyList() }
)

fun createNovelWorkspaceStatusToolDeclaration(): Tool = Tool(
    name = "novel_workspace_status",
    description = """
        Show workspace status: project name, branch, syncStatus, working chapter count,
        and whether plot or manuscript is unresolved. This is read-only.
    """.trimIndent(),
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createNovelWorkspaceWriteToolDeclaration(): Tool = Tool(
    name = "novel_workspace_write",
    description = """
        Write one workspace file by path. Setting, plan, and inbox writes save directly.
        Writing an already collected chapter or plot/ file shows an approval card first.
        `path` is a workspace path from novel_workspace_list. `content` is the new file body
        (front matter optional; the host keeps identity from the path).
    """.trimIndent(),
    parameters = { novelWorkspaceWriteParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createNovelRejectSettingProposalsToolDeclaration(): Tool = Tool(
    name = "novel_reject_setting_proposals",
    description = """
        Reject pending setting proposals on the current branch without writing materials.
        Omit `proposal_ids` or pass an empty array to reject every active proposal at once.
        Pass specific UUIDs from novel_list_setting_proposals to reject only those.
        The change is saved directly into the novel project document.
    """.trimIndent(),
    parameters = { novelRejectSettingProposalsParameters() },
    execute = { emptyList() }
)

fun createMemoryToolDeclaration(): Tool = Tool(
    name = "memory_tool",
    description = """
        Read and update AmberAgent iOS memories. Use `action`:
        - `list`: list saved memories visible under the enabled memory scopes.
        - `read`, `search`, `query`: actively find memories, optionally filtered by `scope`/`kind`; call these to recall more than the injected set when the conversation needs continuity.
        - `status`: check whether memory recall is available.
        - `create`: add a memory with `content`, optional `scope` (`core`, `short_term`, `long_term`), `kind`, `pinned`, `expiresAt`, and `confidence`.
        - `edit`: update an existing memory by `id` with new `content`, and optional `scope`, `kind`, or `pinned`.
        - `delete`: remove a memory by `id`.
        Do not store sensitive personal data. Prefer concise durable preferences, project continuity notes, and explicit user-approved facts.
    """.trimIndent(),
    parameters = { memoryToolParameters() },
    execute = { emptyList() }
)

fun createWorkspaceFileReadToolDeclaration(): Tool = workspaceTool(
    name = "workspace_file_read",
    description = """
        Read text from an AmberAgent iOS Workspace file previously imported by the user.
        Use `file_id` from Workspace UI/tool output or a `/workspace/...` path. This cannot read arbitrary device files.
        Without `start_line`/`end_line`, returns the normal bounded preview (including supported PDF previews).
        With either line parameter, reads the original UTF-8 file by a 1-based inclusive line range;
        omitted `start_line` defaults to 1 and omitted `end_line` defaults to the end of the file.
        `max_chars` still bounds the returned text; the response reports the actual returned line range and total lines.
        On truncation, continue from `end_line + 1` without skipping content.
    """.trimIndent(),
    parameters = workspaceFileReadParameters()
)

fun createWorkspaceFileWriteToolDeclaration(): Tool = workspaceTool(
    name = "workspace_file_write",
    description = """
        Write a UTF-8 text or Markdown file under AmberAgent iOS `/workspace`.
        Use a relative path or `/workspace/...`; traversal and absolute device paths are rejected. Requires foreground approval.
    """.trimIndent(),
    parameters = workspaceFileWriteParameters()
)

fun createWorkspaceFileEditToolDeclaration(): Tool = workspaceTool(
    name = "workspace_file_edit",
    description = """
        Precisely replace text in an existing UTF-8 Workspace file. Read the relevant original lines first.
        `find` must match exactly, including whitespace and newlines, and must identify one occurrence by default.
        If multiple occurrences match, include more surrounding context in `find`; use `replace_all=true` only for an intentional global replacement.
        Missing or ambiguous matches fail without writing. Returns the replacement count and a bounded diff preview.
        Requires foreground approval.
    """.trimIndent(),
    parameters = workspaceFileEditParameters()
)

fun createWorkspaceFileListToolDeclaration(): Tool = workspaceTool(
    name = "workspace_file_list",
    description = "List files currently stored in AmberAgent iOS Workspace, optionally under a path prefix.",
    parameters = workspaceFileListParameters()
)

fun createWorkspaceFileSearchToolDeclaration(): Tool = workspaceTool(
    name = "workspace_file_search",
    description = "Search text previews of AmberAgent iOS Workspace files.",
    parameters = workspaceFileSearchParameters()
)

fun createWorkspaceFileMoveToolDeclaration(): Tool = workspaceTool(
    name = "workspace_file_move",
    description = "Move or rename an AmberAgent iOS Workspace file. Requires foreground approval.",
    parameters = workspaceFileMoveParameters()
)

fun createWorkspaceArtifactReadToolDeclaration(): Tool = workspaceTool(
    name = "workspace_artifact_read",
    description = "Read a saved AmberAgent iOS Workspace artifact by `artifact_id`.",
    parameters = workspaceArtifactReadParameters()
)

fun createWorkspaceArtifactDeleteToolDeclaration(): Tool = workspaceTool(
    name = "workspace_artifact_delete",
    description = "Delete a saved AmberAgent iOS Workspace artifact by `artifact_id`. Requires explicit foreground approval.",
    parameters = workspaceArtifactReadParameters()
)

fun createImageGenToolDeclaration(): Tool = Tool(
    name = "generate_image",
    description = """
        Generate raster images using AmberAgent iOS image generation. Use for photos, paintings,
        illustrations, posters, concept art, wallpapers, product mockups, and other visual results
        where pixels, lighting, texture, composition, or style matter. Prefer detailed English
        prompts. When the user attached an image and wants a style transfer, remake, edit, or
        based-on-this-image result, set use_attached_image=true so the host pads that attached
        reference into Codex image2; do not rely on a text-only redraw of the attachment. You may
        also pass source_image_url for a known earlier chat image URL. Use SVG or markdown diagrams
        for precise editable charts and diagrams unless the user explicitly asks for an artistic
        rendering.
    """.trimIndent().replace("\n", " "),
    parameters = { imageGenParameters() },
    execute = { emptyList() }
)

fun createWebMountStationsToolDeclaration(): Tool = webMountTool(
    name = "wm_stations",
    description = "List configured iOS WebMount stations, enabled state, auth kind, and redacted cookie summary.",
    parameters = webMountStationsParameters()
)

fun createWebMountTabListToolDeclaration(): Tool = webMountTool(
    name = "wm_tab_list",
    description = "List up to three foreground iOS WebMount sessions with redacted URLs, titles, status, and navigation state. Use the returned session_id to bind an agent run to an explicit session.",
    parameters = emptyObjectParameters()
)

fun createWebMountTabNewToolDeclaration(): Tool = webMountTool(
    name = "wm_tab_new",
    description = "Create a new foreground iOS WebMount session and return its session_id for an agent run. iOS keeps at most three sessions and evicts least-recently-used sessions.",
    parameters = webMountTabNewParameters()
)

fun createWebMountTabCloseToolDeclaration(): Tool = webMountTool(
    name = "wm_tab_close",
    description = "Close a foreground iOS WebMount session by session_id. Agent runs must provide it; only direct in-app user operations may omit it to close the current foreground session.",
    parameters = webMountTabCloseParameters()
)

fun createWebMountOpenToolDeclaration(): Tool = webMountTool(
    name = "wm_open",
    description = """
        Open a URL or station in the iOS WebMount session.
        Use `site_id` from wm_stations when possible. Unlisted public hosts are available only while high-risk auto-approve is enabled.
        For local WK sessions, unlisted HTTPS hosts behind a trusted VPN with standard Fake-IP DNS answers are rechecked with Google Public DNS over HTTPS. The original hostname is still loaded through the VPN; this is DNS preflight, not connection IP pinning. Private IP literals, private DNS answers, and failed public DNS checks remain blocked.
        After navigation settles, use wm_visual_read for visual confirmation when a vision-capable model and manual approval or high-risk auto-approval are available.
    """.trimIndent(),
    parameters = webMountOpenParameters()
)

fun createWebMountStateToolDeclaration(): Tool = webMountTool(
    name = "wm_state",
    description = "Read current iOS WebMount WKWebView status, title, redacted URL, and basic page state.",
    parameters = webMountSessionParameters()
)

fun createWebMountObserveToolDeclaration(): Tool = webMountTool(
    name = "wm_observe",
    description = "Observe the current iOS WebMount page: state, visible text, links, interactive elements and DOM visual candidates. Prefer interactive_elements for actions and typeable=true for text entry. A visual candidate may provide interactive_target_ref for its nearest control; single_click_supported=false means it cannot be single-clicked directly. For a collapsed search control, click its control ref, re-observe, then wm_type into the revealed input. Does not expose cookies, tokens or headers. After key actions, use wm_visual_read for visual confirmation when a vision model and the required approval are available.",
    parameters = webMountObserveParameters()
)

fun createWebMountExtractToolDeclaration(): Tool = webMountTool(
    name = "wm_extract",
    description = "Extract readable text, links, or interactive element summaries from the current iOS WebMount page.",
    parameters = webMountExtractParameters()
)

fun createWebMountGetToolDeclaration(): Tool = webMountTool(
    name = "wm_get",
    description = "Read one visible element's text, checked value, or non-sensitive attribute from the current iOS WebMount page. Raw HTML is not available.",
    parameters = webMountGetParameters()
)

fun createWebMountVisualSnapshotToolDeclaration(): Tool = webMountTool(
    name = "wm_visual_snapshot",
    description = "Return visible DOM visual candidates such as image, iframe, canvas, video, SVG, and text block rectangles. Prefer interactive_target_ref when a candidate provides one, because it identifies the real interactive control. Do not directly single-click a candidate whose single_click_supported is false. No external vision model is called.",
    parameters = webMountSessionParameters()
)

fun createWebMountVisualReadToolDeclaration(): Tool = webMountTool(
    name = "wm_visual_read",
    description = "For the local iOS WKWebView backend only, capture the current WebMount viewport and ask the current chat model first when it natively supports images; otherwise use the configured auxiliary vision model to verify what is visibly rendered. Use after navigation or a key browser action when visual confirmation matters; use wm_observe for DOM targets. This sends the screenshot to the provider and requires manual approval or high-risk auto-approval. It never clicks, types, solves CAPTCHAs, or treats wm_visual_snapshot as an image. If vision is unavailable, the backend is remote, or neither approval path is available, explicitly say visual verification has not occurred and do not claim visual confirmation succeeded; DOM-verifiable results may still be reported honestly. An ok result only means the image was analyzed, not that a browser action succeeded.",
    parameters = webMountVisualReadParameters(),
    needsApproval = true
)

fun createWebMountScreenshotToolDeclaration(): Tool = webMountTool(
    name = "wm_screenshot",
    description = "Capture only the current iOS WebMount viewport to a local artifact after manual approval or high-risk auto-approval. Returns artifact metadata, not base64 image data.",
    parameters = webMountSessionParameters(),
    needsApproval = true
)

fun createWebMountBackToolDeclaration(): Tool = webMountTool(
    name = "wm_back",
    description = "Navigate the current iOS WebMount WKWebView session backward.",
    parameters = webMountSessionParameters()
)

fun createWebMountForwardToolDeclaration(): Tool = webMountTool(
    name = "wm_forward",
    description = "Navigate the current iOS WebMount WKWebView session forward.",
    parameters = webMountSessionParameters()
)

fun createWebMountClearSessionToolDeclaration(): Tool = webMountTool(
    name = "wm_clear_session",
    description = """
        Clear cookies and website data for one iOS WebMount station.
        This requires manual approval or high-risk auto-approval.
    """.trimIndent(),
    parameters = webMountClearSessionParameters(),
    needsApproval = true
)

fun createWebMountSiteAddToolDeclaration(): Tool = webMountTool(
    name = "wm_site_add",
    description = "Add and enable a local iOS WebMount station after manual approval or high-risk auto-approval. The URL allowlist is synced; no login or OAuth is performed.",
    parameters = webMountSiteAddParameters(),
    needsApproval = true
)

fun createWebMountSiteRemoveToolDeclaration(): Tool = webMountTool(
    name = "wm_site_remove",
    description = "Remove a local iOS WebMount station after manual approval or high-risk auto-approval. This does not clear cookies or website data.",
    parameters = webMountSiteRemoveParameters(),
    needsApproval = true
)

fun createWebMountClickToolDeclaration(): Tool = webMountTool(
    name = "wm_click",
    description = "Click a visible element on the current iOS WebMount page, including accessible same-origin frames. Prefer an actionable interactive_elements ref or a visual candidate's interactive_target_ref. Use click_count=2 for a double-click, such as opening a folder, then verify the resulting page. Agent calls must use a target ref from the latest observation; CSS selectors remain available for direct user actions.",
    parameters = webMountTargetParameters(requireSessionSnapshot = true, includeClickCount = true)
)

fun createWebMountTapToolDeclaration(): Tool = webMountTool(
    name = "wm_tap",
    description = "Tap the current iOS WebMount page. Agent calls must use a target ref from the latest observation; coordinates and CSS selectors remain available for direct user actions.",
    parameters = webMountTargetParameters(includeCoordinates = true, requireSessionSnapshot = true)
)

fun createWebMountTypeToolDeclaration(): Tool = webMountTool(
    name = "wm_type",
    description = "Type text into an input or contenteditable element on the current iOS WebMount page. Use a typeable=true target ref from the latest observation. If a search input is not yet visible, focus its control and re-observe first.",
    parameters = webMountTextInteractionParameters(requireSessionSnapshot = true)
)

fun createWebMountKeysToolDeclaration(): Tool = webMountTool(
    name = "wm_keys",
    description = "Send a short key sequence to the current iOS WebMount page or focused field.",
    parameters = webMountTextInteractionParameters(requireSessionSnapshot = true)
)

fun createWebMountScrollToolDeclaration(): Tool = webMountTool(
    name = "wm_scroll",
    description = "Scroll the page, an accessible same-origin iframe, or a scrollable container using its target ref; other element targets are scrolled into view.",
    parameters = webMountScrollParameters(requireSessionSnapshot = true)
)

fun createWebMountSelectToolDeclaration(): Tool = webMountTool(
    name = "wm_select",
    description = "Select an option value in a select element on the current iOS WebMount page. Agent calls must use a target ref from the latest observation.",
    parameters = webMountTextInteractionParameters(requireSessionSnapshot = true)
)

fun createWebMountFindToolDeclaration(): Tool = webMountTool(
    name = "wm_find",
    description = "Find matches on the current iOS WebMount page. Provide exactly one non-empty selector or text query. For a custom search control, after clicking to focus, use wm_find to locate the actual input and then call wm_type with that input ref.",
    parameters = webMountFindParameters()
)

fun createWebMountWaitToolDeclaration(): Tool = webMountTool(
    name = "wm_wait",
    description = "Wait with a bounded deadline for DOM stability, a selector, visible text, URL fragment, ready state, or an explicit delay. Returns a structured timeout instead of pretending the condition matched.",
    parameters = webMountWaitParameters()
)

/**
 * Jev Phase 3: bounded fast web loop. The main model explicitly calls this to
 * enter the loop; runtime budgets (100 decisions / 600s / 10 no-progress) always
 * cap the caller-provided values, the action whitelist can only be narrowed by
 * the input, and every executed action still goes through the existing
 * per-action approval and ledger path. Completion is verified from page state
 * via completion_text — a successful click alone never proves the goal.
 */
fun createWebMountRunGoalToolDeclaration(): Tool = webMountTool(
    name = "wm_run_goal",
    description = "Use for one concrete, verifiable goal on an already-open WebMount session when the allowed actions are read-only navigation or inspection, selection, draft-only text entry, or a read-only search. Do not use for vague goals, sending or publishing content, destructive or account-changing actions, payment, login, or any task that needs a human decision during the loop; use individual wm_* tools or ask the user. Provide session_id, goal, an allowed_actions subset of scroll/select/click_nav/type_draft/submit_readonly_search, optional draft_value, and completion_text that proves completion from page state. The loop returns structured status and steps, and each action still passes the host approval and ledger checks.",
    parameters = InputSchema.Obj(
        properties = buildJsonObject {
            put("session_id", buildJsonObject {
                put("type", "string")
                put("description", "Open WebMount session to operate on.")
            })
            put("goal", buildJsonObject {
                put("type", "string")
                put("description", "One concrete, verifiable goal for this loop.")
            })
            put("allowed_actions", buildJsonObject {
                put("type", "array")
                put("items", buildJsonObject { put("type", "string") })
                put("description", "Allowed action names; must be a subset of scroll, select, click_nav, type_draft, submit_readonly_search. Values beyond the whitelist are dropped.")
            })
            put("draft_value", buildJsonObject {
                put("type", "string")
                put("description", "Draft text for type_draft actions; missing value removes type_draft candidates.")
            })
            put("completion_text", buildJsonObject {
                put("type", "string")
                put("description", "Required. Text that must appear in the page URL or visible element labels for the goal to count as completed; the loop refuses to run without it.")
            })
            put("max_action_decisions", buildJsonObject {
                put("type", "number")
                put("description", "Optional smaller action-decision budget (hard cap 100).")
            })
            put("max_seconds", buildJsonObject {
                put("type", "number")
                put("description", "Optional smaller time budget in seconds (hard cap 600).")
            })
            put("max_no_progress", buildJsonObject {
                put("type", "number")
                put("description", "Optional smaller no-progress limit before handback (hard cap 10).")
            })
        }
    )
)

/**
 * wm_act：一次调用串行执行一小批页面动作。宿主逐步走与单动作相同的
 * 审批/快照/控制权闸门；find 步的首个匹配 ref 自动喂给缺省 target 的
 * 后续步；任何 document 导航都熔断剩余步骤。
 */
fun createWebMountActToolDeclaration(): Tool = webMountTool(
    name = "wm_act",
    description = "Execute a small ordered batch of page actions in one call. Each step runs serially through the same approval, snapshot, and control gates as the matching single tool. A find step feeds its first match ref to a following step that omits target. Any document navigation aborts the remaining steps. Use for 1-3 step tasks like find-then-click or scroll-then-click instead of wm_run_goal. Steps support action=find|wait|click|tap|type|keys|scroll|select with the same fields as the corresponding wm_* tools; never submits forms, deletes, pays, or logs in.",
    parameters = InputSchema.Obj(
        properties = buildJsonObject {
            put("session_id", buildJsonObject {
                put("type", "string")
                put("description", "Open WebMount session to operate on.")
            })
            put("snapshot_id", buildJsonObject {
                put("type", "string")
                put("description", "Required for agent calls. Bind to the snapshot_id returned by the latest wm_observe/wm_find to prove the batch was planned against recent page state.")
            })
            put("steps", buildJsonObject {
                put("type", "array")
                put("description", "Ordered action steps (max 8). Each step: action=find|wait|click|tap|type|keys|scroll|select plus that action's fields (target, text/value, by_y, key, condition, timeout_ms, ...). A step without target uses the ref from the latest find step.")
                put("items", buildJsonObject {
                    put("type", "object")
                    put("description", "One batch step, e.g. {\"action\":\"find\",\"text\":\"More\"} then {\"action\":\"click\"}.")
                })
            })
        },
        required = listOf("session_id", "snapshot_id", "steps")
    )
)

fun createSelectedFileReadToolDeclaration(): Tool = Tool(
    name = "file_read_selected",
    description = "Read the text preview of the file the user explicitly selected in AmberAgent iOS.",
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createIshHandoffToolDeclaration(): Tool = Tool(
    name = "ish_handoff",
    description = """
        Prepare a command or shell script for manual execution in the external iSH app on iOS.
        This is a foreground handoff only: AmberAgent writes a script copy, copies a paste-ready
        iSH command to the clipboard, and returns handoff metadata. It does not run iSH in the
        background and cannot read stdout, stderr, exit code, or files from the iSH sandbox.
        Use this only when the user explicitly wants to run something in iSH and can paste it
        into iSH themselves.
    """.trimIndent().replace("\n", " "),
    parameters = { ishHandoffParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createIosIshExecuteToolDeclaration(): Tool = Tool(
    name = "ios_ish_execute",
    description = """
        Execute a POSIX shell command or script inside AmberAgent iOS's isolated embedded iSH guest.
        Available only in the iOS ExperimentalGPL build after explicit foreground approval. Foreground
        mode returns stdout, stderr, exit_code, timeout, and status. Set background=true for a process-local,
        asynchronous non-PTY job with no stdin; it returns job_id for terminal_job_read, terminal_job_wait,
        or terminal_job_stop. Background here means Agent-asynchronous, not durable iOS background execution:
        app relaunch marks unfinished jobs interrupted. Scripts may use pipes, redirects, package installation,
        and the writable /workspace guest directory. Captured stdout and stderr tails are capped at 128 KiB each.
    """.trimIndent().replace("\n", " "),
    parameters = { iosIshExecuteParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createTerminalExecuteToolDeclaration(): Tool = Tool(
    name = "terminal_execute",
    description = """
        Execute one bounded, non-interactive command on a trusted Remote SSH profile configured in AmberAgent iOS.
        The command runs in the foreground after explicit approval and returns separate stdout, stderr, exit_code,
        timeout, and status fields. This tool does not allocate a PTY, keep an interactive session, install packages,
        or create a durable background job. Omit profile_id to use the selected default SSH profile.
    """.trimIndent().replace("\n", " "),
    parameters = { terminalExecuteParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createIosShellExecuteToolDeclaration(): Tool = Tool(
    name = "ios_shell_execute",
    description = """
        Execute one bounded, non-interactive command inside AmberShell, AmberAgent iOS's stable local command environment.
        The command runs in the foreground after explicit approval and returns separate stdout, stderr, exit_code,
        and status fields. It supports pwd, ls, echo, cat, mkdir, touch, cp, mv, rm, head, tail, wc, printf,
        grep, sort, uniq, cut, tr, basename, dirname, env, date, and uname in the app-owned /workspace directory.
        Builds with bundled CPython 3.14 also accept restricted `python -c <code>` snippets; plugin_sdk reports
        the current build's Python availability. Python has no pip, network, PTY, or host file access.
        It allows at most three pipeline stages and only <, >, and 2> redirection. It does not invoke a system shell,
        allocate a PTY, install packages, or create a durable background job; control flow, globbing, and command
        substitution are unavailable. Optional stdin is UTF-8 text capped at 64 KiB. `timeout_seconds` is a
        foreground cooperative timeout/cancellation request: pure Python bytecode can be interrupted, but Python
        blocked in a native C extension cannot be force-terminated, so timeout/cancel may wait for that call to return.
    """.trimIndent().replace("\n", " "),
    parameters = { iosShellExecuteParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createTerminalJobStartToolDeclaration(): Tool = Tool(
    name = "terminal_job_start",
    description = """
        Start one bounded, asynchronous, non-PTY command on a trusted Remote SSH profile configured in AmberAgent iOS.
        Returns a process-local job_id immediately so terminal_job_read or terminal_job_wait can observe stdout, stderr,
        status, and exit code, and terminal_job_stop can cancel the process while this app process still owns it. Amber persists
        a snapshot for inspection, but app relaunch marks an unfinished job interrupted because Remote SSH process recovery is
        not available. Explicit foreground approval is required.
    """.trimIndent().replace("\n", " "),
    parameters = { terminalJobStartParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createTerminalJobReadToolDeclaration(): Tool = Tool(
    name = "terminal_job_read",
    description = "Read the persisted snapshot and output tails for one AmberAgent iOS terminal job_id returned by Remote SSH terminal_job_start or background embedded iSH execution. This is read-only and does not allocate a PTY or change the job.",
    parameters = { terminalJobIdParameters() },
    execute = { emptyList() }
)

fun createTerminalJobWaitToolDeclaration(): Tool = Tool(
    name = "terminal_job_wait",
    description = "Wait briefly for one AmberAgent iOS Remote SSH or embedded iSH job to finish or change, then return its current snapshot. Observer timeout never stops the underlying job.",
    parameters = { terminalJobWaitParameters() },
    execute = { emptyList() }
)

fun createTerminalJobStopToolDeclaration(): Tool = Tool(
    name = "terminal_job_stop",
    description = "Stop one running AmberAgent iOS Remote SSH or embedded iSH job while this app process still owns it. Repeated stop calls are idempotent. Explicit foreground approval is required.",
    parameters = { terminalJobIdParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

/**
 * P3-b: `exec` tool — runs JavaScript (ES2020) in a sandbox (iOS:
 * JavaScriptCore via IOSJsSandboxEngine; Android: QuickJS via eval_javascript,
 * which stays as its own legacy tool). No DOM, no Node, no fs, no network, no
 * imports. The result is the value of the last expression (JSON-ified);
 * console.log/info/warn/error are captured into `logs`. Inside the sandbox a
 * `tools` object exposes the currently visible tool set: nested calls are
 * SYNCHRONOUS (the JS thread blocks while the host executes; no
 * await/Promise needed, Promise.all concurrency is not supported in v1) and
 * inherit each tool's own approval policy — the exec container itself never
 * asks for extra approval. Approval flags mirror Android `eval_javascript`
 * (Tool defaults: needsApproval=false, allowsAutoApproval=true) — the
 * per-assistant/global opt-in switch is the gate, not a per-call approval
 * card. iOS execution lives in ChatToolRuntime (Swift); `execute` is empty
 * here, same pattern as createSearchWebToolDeclaration.
 */
fun createExecToolDeclaration(): Tool = Tool(
    name = "exec",
    description = """
        Run JavaScript (ES2020) in a sandbox. No DOM, no Node, no fs, no network, no imports.
        Use console.log for output; the last expression's value is returned.
        Inside the sandbox, `tools` exposes the tools visible in this run; tools.* calls are
        synchronous (no await/Promise needed; Promise.all concurrency is not supported in v1),
        and nested calls inherit each tool's own approval policy.
        The global `ALL_TOOLS` lists every callable tool's `name` and `description`; filter it to discover tools instead of guessing names.
        NOT for generating SVG/widgets/HTML.
    """.trimIndent().replace("\n", " "),
    parameters = { execParameters() },
    needsApproval = false,
    allowsAutoApproval = true,
    execute = { emptyList() }
)

private fun execParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("code", buildJsonObject {
            put("type", "string")
            put("description", "Required. The JavaScript source to evaluate (ES2020). Raw code, no markdown fences.")
        })
        put("timeout_ms", buildJsonObject {
            put("type", "integer")
            put("description", "Optional. Maximum evaluation time in milliseconds, clamped to [1000, 30000]; defaults to 10000. When this deadline elapses, exec yields status=running with a cell_id; call wait with that cell_id to retrieve the eventual result. A later wait with terminate=true abandons the cell and discards its result, but JavaScriptCore may keep the evaluation running until it returns; its context is never reused.")
        })
        put("max_output_chars", buildJsonObject {
            put("type", "integer")
            put("description", "Optional. Maximum characters for the returned payload, clamped to [1, 100000]; defaults to 10000.")
        })
    },
    required = listOf("code"),
)

/**
 * P3-c: `wait` tool — continues a yielded `exec` cell. When an exec evaluation
 * runs past its `timeout_ms`, the handle is NOT dropped: exec returns
 * "Script running with cell ID {cell_id}" and the evaluation keeps running on
 * its own queue. `wait` blocks on that cell until it reaches a terminal state
 * (Completed | Terminated | Failed | interrupted) or the wait timeout elapses,
 * and returns `{status, output, logs}`. `terminate=true` marks the cell
 * Terminated (abandon semantics: JavaScriptCore cannot force-kill a runaway
 * script, it keeps burning CPU until it ends by itself). Cells and the
 * `store`/`load` KV are scoped per conversation and survive across runs;
 * every wait consumes one ordinary tool-resume budget slot (no separate
 * budget mechanism). Approval flags mirror `exec` — the container never asks
 * for extra approval, the per-assistant/global opt-in switch is the gate.
 * iOS execution lives in ChatToolRuntime (Swift); `execute` is empty here,
 * same pattern as createExecToolDeclaration.
 */
fun createWaitToolDeclaration(): Tool = Tool(
    name = "wait",
    description = """
        Wait for a running exec cell to finish. `cell_id` is returned by exec when a script times out (yield).
        Blocks until the cell completes or the wait timeout elapses; returns {status, output, logs}.
        terminate=true abandons the cell (status=terminated).
    """.trimIndent().replace("\n", " "),
    parameters = { waitParameters() },
    needsApproval = false,
    allowsAutoApproval = true,
    execute = { emptyList() }
)

private fun waitParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("cell_id", buildJsonObject {
            put("type", "string")
            put("description", "Required. The cell ID returned by exec when a script timed out (yield).")
        })
        put("timeout_ms", buildJsonObject {
            put("type", "integer")
            put("description", "Optional. Maximum wait in milliseconds, clamped to [1000, 60000]; defaults to 10000. A wait that elapses while the cell is still running returns its current running status instead of failing.")
        })
        put("terminate", buildJsonObject {
            put("type", "boolean")
            put("description", "Optional. When true, mark the cell terminated (abandon) and return its terminal status immediately instead of waiting.")
        })
    },
    required = listOf("cell_id"),
)

fun createPermissionsStatusToolDeclaration(): Tool = Tool(
    name = "permissions_status",
    description = "Return AmberAgent iOS capability and permission status for tools available on this device.",
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createRuntimeStatusToolDeclaration(): Tool = Tool(
    name = "runtime_status",
    description = "Return AmberAgent internal runtime status not visible as tools: the Jev fast-judgment service (per-use-case off/shadow/active modes, whether an API key is configured, budget and recent usage), feature gates, and tool runtime flags. Read-only with no side effects. Use when asked what Jev is, whether a capability is enabled, or about the agent's own state.",
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createWeatherReadToolDeclaration(): Tool = Tool(
    name = "weather_read",
    description = """
        Read current conditions and a bounded five-day forecast through Apple WeatherKit.
        Provide one named `location`, which does not need device location permission, or set
        `use_current_location` to true. Never provide both. Results include Apple Weather
        attribution and are read-only.
    """.trimIndent(),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("location", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional city or place name, maximum 80 characters.")
                })
                put("use_current_location", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Optional. Set true to request the device's current location in the foreground.")
                })
            },
        )
    },
    execute = { emptyList() },
)

fun createHealthSummaryReadToolDeclaration(): Tool = Tool(
    name = "health_summary_read",
    description = """
        Read a compact HealthKit activity and sleep summary for the current user after foreground permission.
        Returns daily steps, active energy, exercise minutes, sleep duration, and optional recent workouts.
        Use only when the user explicitly asks for personal health or fitness analysis.
    """.trimIndent(),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("days", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional number of recent days, clamped to 1...30. Defaults to 7.")
                })
                put("include_workouts", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Optional. Include up to 20 recent workout summaries. Defaults to true.")
                })
            },
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createCalendarEventsListToolDeclaration(): Tool = Tool(
    name = "calendar_events_list",
    description = "Read calendar events in a bounded time range after the user grants EventKit access.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("start_at", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional ISO-8601 start time. Defaults to now.")
                })
                put("end_at", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional ISO-8601 end time. Defaults to seven days after start_at.")
                })
                put("limit", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional maximum results, clamped to 1...100. Defaults to 30.")
                })
            },
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createCalendarEventCreateToolDeclaration(): Tool = Tool(
    name = "calendar_event_create",
    description = "Create one event in Apple Calendar. The host requires foreground approval before writing.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("title", buildJsonObject { put("type", "string") })
                put("start_at", buildJsonObject {
                    put("type", "string")
                    put("description", "ISO-8601 event start time.")
                })
                put("end_at", buildJsonObject {
                    put("type", "string")
                    put("description", "ISO-8601 event end time; must be later than start_at.")
                })
                put("location", buildJsonObject { put("type", "string") })
                put("notes", buildJsonObject { put("type", "string") })
                put("calendar_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional EventKit calendar identifier. Omit to use the default calendar.")
                })
                putCalendarRecurrenceFields()
            },
            required = listOf("title", "start_at", "end_at"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createCalendarEventUpdateToolDeclaration(): Tool = Tool(
    name = "calendar_event_update",
    description = "Update one existing Apple Calendar event by event_id. Only provided fields change. Foreground approval is required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("event_id", buildJsonObject { put("type", "string") })
                put("title", buildJsonObject { put("type", "string") })
                put("start_at", buildJsonObject { put("type", "string"); put("description", "Optional ISO-8601 start time.") })
                put("end_at", buildJsonObject { put("type", "string"); put("description", "Optional ISO-8601 end time.") })
                put("location", buildJsonObject { put("type", "string"); put("description", "Optional. Pass an empty string to clear.") })
                put("notes", buildJsonObject { put("type", "string"); put("description", "Optional. Pass an empty string to clear.") })
                put("calendar_id", buildJsonObject { put("type", "string"); put("description", "Optional destination EventKit calendar identifier.") })
                putCalendarRecurrenceFields()
            },
            required = listOf("event_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createCalendarEventDeleteToolDeclaration(): Tool = Tool(
    name = "calendar_event_delete",
    description = "Delete one existing Apple Calendar event by event_id. Foreground approval is required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("event_id", buildJsonObject { put("type", "string") })
            },
            required = listOf("event_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createRemindersListToolDeclaration(): Tool = Tool(
    name = "reminders_list",
    description = "Read a bounded list of Apple Reminders after the user grants EventKit access.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("include_completed", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Optional. Include completed reminders. Defaults to false.")
                })
                put("limit", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional maximum results, clamped to 1...100. Defaults to 30.")
                })
            },
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createReminderCreateToolDeclaration(): Tool = Tool(
    name = "reminder_create",
    description = "Create one item in the user's default Apple Reminders list. The host requires foreground approval before writing.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("title", buildJsonObject { put("type", "string") })
                put("due_at", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional ISO-8601 due time.")
                })
                put("notes", buildJsonObject { put("type", "string") })
                put("priority", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional EventKit priority from 0 (none) to 9.")
                })
                put("list_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional EventKit reminders-list identifier. Omit to use the default list.")
                })
            },
            required = listOf("title"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createReminderUpdateToolDeclaration(): Tool = Tool(
    name = "reminder_update",
    description = "Update one Apple Reminder by reminder_id. Only provided fields change. Foreground approval is required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("reminder_id", buildJsonObject { put("type", "string") })
                put("title", buildJsonObject { put("type", "string") })
                put("due_at", buildJsonObject { put("type", "string"); put("description", "Optional ISO-8601 due time.") })
                put("remove_due_date", buildJsonObject { put("type", "boolean"); put("description", "Optional. Set true to clear the due date.") })
                put("notes", buildJsonObject { put("type", "string"); put("description", "Optional. Pass an empty string to clear.") })
                put("priority", buildJsonObject { put("type", "integer"); put("description", "Optional EventKit priority from 0 to 9.") })
                put("list_id", buildJsonObject { put("type", "string"); put("description", "Optional destination reminders-list identifier.") })
            },
            required = listOf("reminder_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createReminderDeleteToolDeclaration(): Tool = Tool(
    name = "reminder_delete",
    description = "Delete one Apple Reminder by reminder_id. Foreground approval is required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("reminder_id", buildJsonObject { put("type", "string") })
            },
            required = listOf("reminder_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createReminderCompleteToolDeclaration(): Tool = Tool(
    name = "reminder_complete",
    description = "Mark one Apple Reminder complete by identifier. The host requires foreground approval before writing.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("reminder_id", buildJsonObject { put("type", "string") })
            },
            required = listOf("reminder_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

private fun JsonObjectBuilder.putCalendarRecurrenceFields() {
    put("recurrence", buildJsonObject {
        put("type", "string")
        put("description", "Optional recurrence. Use none to remove recurrence on update.")
        put("enum", buildJsonArray { add("none"); add("daily"); add("weekly"); add("monthly") })
    })
    put("recurrence_interval", buildJsonObject {
        put("type", "integer")
        put("description", "Optional recurrence interval, clamped to 1...30. Defaults to 1.")
    })
    put("recurrence_end_at", buildJsonObject {
        put("type", "string")
        put("description", "Optional ISO-8601 recurrence end time; must be later than event start.")
    })
}

fun createNotificationScheduleToolDeclaration(): Tool = Tool(
    name = "notification_schedule",
    description = "Schedule one local Amber notification. The host requires foreground approval before scheduling it.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("title", buildJsonObject { put("type", "string") })
                put("body", buildJsonObject { put("type", "string") })
                put("fire_at", buildJsonObject {
                    put("type", "string")
                    put("description", "ISO-8601 time at least five seconds in the future.")
                })
            },
            required = listOf("title", "fire_at"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createNotificationCancelToolDeclaration(): Tool = Tool(
    name = "notification_cancel",
    description = "Cancel a local notification previously scheduled by the Amber agent.",
    parameters = { emptyObjectParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createAlarmScheduleToolDeclaration(): Tool = Tool(
    name = "alarm_schedule",
    description = "Schedule one prominent AlarmKit alarm or timer that can sound through Focus or silent mode. Foreground approval is always required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("title", buildJsonObject { put("type", "string"); put("description", "Required, maximum 80 characters.") })
                put("kind", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("one_time"); add("weekly"); add("timer") })
                })
                put("fire_at", buildJsonObject { put("type", "string"); put("description", "For one_time only: ISO-8601 time at least five seconds in the future.") })
                put("weekdays", buildJsonObject {
                    put("type", "array")
                    put("description", "For weekly only. One or more English weekday names.")
                    put("items", buildJsonObject {
                        put("type", "string")
                        put("enum", buildJsonArray {
                            add("sunday"); add("monday"); add("tuesday"); add("wednesday")
                            add("thursday"); add("friday"); add("saturday")
                        })
                    })
                })
                put("hour", buildJsonObject { put("type", "integer"); put("description", "For weekly only: 0...23.") })
                put("minute", buildJsonObject { put("type", "integer"); put("description", "For weekly only: 0...59.") })
                put("duration_seconds", buildJsonObject { put("type", "number"); put("description", "For timer only: 10...86400 seconds.") })
            },
            required = listOf("title", "kind"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createAlarmsListToolDeclaration(): Tool = Tool(
    name = "alarms_list",
    description = "List only the active alarms and timers previously scheduled by Amber. Foreground approval is required.",
    parameters = { emptyObjectParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createAlarmCancelToolDeclaration(): Tool = Tool(
    name = "alarm_cancel",
    description = "Cancel one Amber-owned AlarmKit alarm by alarm_id. Foreground approval is always required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("alarm_id", buildJsonObject { put("type", "string") })
            },
            required = listOf("alarm_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createContactsPickToolDeclaration(): Tool = Tool(
    name = "contacts_pick",
    description = "Present the foreground system contact picker, then ask the user to confirm the selected contacts before returning only those contacts to the current agent. Never enumerates the address book.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("max_count", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional maximum selected contacts, 1...8. Defaults to 8.")
                })
            },
        )
    },
    needsApproval = false,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createPhotosPickToolDeclaration(): Tool = Tool(
    name = "photos_pick",
    description = "Present the foreground system photo picker, copy only the chosen images into bounded app-owned storage, and ask the user to confirm before returning them to the current agent. Never searches or enumerates the photo library.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("max_count", buildJsonObject {
                    put("type", "integer")
                    put("description", "Optional maximum selected images, 1...4. Defaults to 4.")
                })
            },
        )
    },
    needsApproval = false,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createJournalingSuggestionPickToolDeclaration(): Tool = Tool(
    name = "journaling_suggestion_pick",
    description = "Present Apple's foreground Journaling Suggestions picker and ask the user to confirm the single chosen suggestion before returning it to the current agent. Requires the signed Journaling Suggestions entitlement.",
    parameters = { emptyObjectParameters() },
    needsApproval = false,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

private fun workoutPlanProperties(includeSchedule: Boolean): JsonObject = buildJsonObject {
    put("title", buildJsonObject {
        put("type", "string")
        put("description", "Short user-visible plan name, maximum 60 characters.")
    })
    put("kind", buildJsonObject {
        put("type", "string")
        put("enum", buildJsonArray { add("goal"); add("pacer"); add("intervals") })
    })
    put("activity", buildJsonObject {
        put("type", "string")
        put("enum", buildJsonArray { add("running"); add("walking"); add("cycling"); add("hiking") })
    })
    put("location", buildJsonObject {
        put("type", "string")
        put("description", "Optional; defaults to outdoor.")
        put("enum", buildJsonArray { add("indoor"); add("outdoor") })
    })
    put("goal_type", buildJsonObject {
        put("type", "string")
        put("description", "For kind=goal only.")
        put("enum", buildJsonArray { add("time"); add("distance") })
    })
    put("goal_value", buildJsonObject {
        put("type", "number")
        put("description", "For a time goal: minutes. For a distance goal: kilometers.")
    })
    put("distance_km", buildJsonObject {
        put("type", "number")
        put("description", "For kind=pacer only.")
    })
    put("duration_minutes", buildJsonObject {
        put("type", "number")
        put("description", "For kind=pacer only.")
    })
    put("work_seconds", buildJsonObject {
        put("type", "number")
        put("description", "For kind=intervals only; 10...3600 seconds.")
    })
    put("recovery_seconds", buildJsonObject {
        put("type", "number")
        put("description", "For kind=intervals only; 10...3600 seconds.")
    })
    put("repetitions", buildJsonObject {
        put("type", "integer")
        put("description", "For kind=intervals only; 1...20.")
    })
    put("warmup_minutes", buildJsonObject {
        put("type", "number")
        put("description", "Optional for intervals; 0...120 minutes.")
    })
    put("cooldown_minutes", buildJsonObject {
        put("type", "number")
        put("description", "Optional for intervals; 0...120 minutes.")
    })
    if (includeSchedule) {
        put("schedule_at", buildJsonObject {
            put("type", "string")
            put("description", "ISO-8601 time between one minute and one year in the future.")
        })
    }
}

fun createWorkoutPlanPreviewToolDeclaration(): Tool = Tool(
    name = "workout_plan_preview",
    description = "Validate and preview a small WorkoutKit plan without reading or writing HealthKit and without scheduling it. This is fitness planning, not medical advice.",
    parameters = {
        InputSchema.Obj(
            properties = workoutPlanProperties(includeSchedule = false),
            required = listOf("title", "kind", "activity"),
        )
    },
    execute = { emptyList() },
)

fun createWorkoutScheduleToolDeclaration(): Tool = Tool(
    name = "workout_schedule",
    description = "Schedule one validated workout plan in Apple's Workout app. Requires a paired supported Watch, WorkoutKit authorization, an explicit user request, and foreground approval.",
    parameters = {
        InputSchema.Obj(
            properties = workoutPlanProperties(includeSchedule = true),
            required = listOf("title", "kind", "activity", "schedule_at"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createScheduledWorkoutsListToolDeclaration(): Tool = Tool(
    name = "workouts_scheduled_list",
    description = "List only active WorkoutKit plans previously scheduled by Amber, reconciled by their stable Amber plan IDs.",
    parameters = { emptyObjectParameters() },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createScheduledWorkoutRemoveToolDeclaration(): Tool = Tool(
    name = "workout_scheduled_remove",
    description = "Remove one Amber-owned WorkoutKit plan by workout_id. Foreground approval is always required.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("workout_id", buildJsonObject { put("type", "string") })
            },
            required = listOf("workout_id"),
        )
    },
    needsApproval = true,
    mandatoryApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() },
)

fun createToolsListToolDeclaration(): Tool = Tool(
    name = "tools_list",
    description = "List the tools currently exposed to this iOS sub-agent run and their intended use.",
    parameters = { emptyObjectParameters() },
    execute = { emptyList() }
)

fun createSubAgentReportToolDeclaration(): Tool = Tool(
    name = "subagent_report",
    description = """
        Finish a sub-agent run by reporting a compact structured result for the supervisor.
        Include summary, findings, evidence, risks, recommended_next_steps, and confidence when available.
    """.trimIndent(),
    parameters = { subAgentReportParameters() },
    execute = { emptyList() }
)

/**
 * P1-c: spawn a child agent thread. The child runs asynchronously within its
 * assigned tool scope and can delegate again when spawn_agent is allowed
 * (depth is capped by the harness). Its conversation is forked from this thread's history
 * (optionally truncated by `fork_turns`), receives the initial `message` as a
 * NEW_TASK, and its final answer is delivered back through the mailbox when it
 * finishes. `task_name` must be lowercase letters, digits and underscores; the
 * canonical agent path is `/root/{task_name}` (or `/root/{parent_task}/{task_name}`
 * for grandchildren). Use `list_agents` to inspect threads and
 * `interrupt_agent` to stop a child without destroying its thread.
 */
fun createSpawnAgentToolDeclaration(): Tool = Tool(
    name = "spawn_agent",
    description = """
        Spawn a child agent thread that runs asynchronously. Access to the parent
        tool catalog is constrained by the selected role and tool_scope. A child
        can spawn its own subagents only when spawn_agent is in its allowed scope.
        The child receives a
        fork of this thread's history (truncated by fork_turns) plus the initial
        `message` as its NEW_TASK, and delivers its FINAL_ANSWER back to this thread
        when it finishes. task_name must be lowercase letters, digits and underscores;
        the canonical agent path is /root/{task_name} (or
        /root/{parent_task}/{task_name} for grandchildren). Inspect threads with
        list_agents; stop a child with interrupt_agent (the thread stays addressable).
        The child starts in the background so the parent can continue. Keep the
        user conversation available; do not repeatedly poll or wait for children.
        When no independent work remains, finish your reply or call wait_agent
        to yield the foreground turn. Reports arrive automatically. Use role_id for a built-in role
        (explorer, historian, oracle, designer, writer, fixer, or browser).
        When dynamic subagents are enabled, system_prompt, context, tool_scope and
        skill_names define a one-off role. For each new child, let the current
        parent model choose a short lowercase English first name, inspect
        list_agents when sibling names may already exist, avoid reusing a sibling
        name, and never add a numeric suffix yourself. Keep the returned
        agent_path for followups. Tool scope is enforced by the child execution
        and background recovery, not only described in the prompt.
        The user's subagent settings enforce the concurrent-child limit (up to
        10, excluding the parent) and each child's runtime timeout. list_agents
        reports the current limits and available model_pool. With a configured
        pool, omit model_id for automatic distribution across available providers
        and models, or select an exact pool model id. reasoning_level must be
        supported by that model; omission uses its configured pool default.
        Saved role model overrides and existing child followups retain their
        selected model unless an allowed explicit selection changes it. An empty
        pool follows the parent model. Do not invent model ids or retry a failed
        task blindly when a tool's side-effect outcome is unknown.
    """.trimIndent(),
    parameters = { spawnAgentParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

/** P1-c: list the agent threads spawned from this thread (and their transitive children). */
fun createListAgentsToolDeclaration(): Tool = Tool(
    name = "list_agents",
    description = """
        List the agent threads spawned from this thread, including transitive
        children: canonical agent path, child thread id, nickname, role assistant,
        thread status (Open/Closed) and the latest run status of each child.
        Optionally filter by a path prefix.
        Also reports subagent concurrency and timeout settings, current model
        and provider occupancy, and the user's available model_pool with model
        ids and supported/default reasoning levels for spawn_agent.
    """.trimIndent(),
    parameters = { listAgentsParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

/** P1-c: interrupt a child agent's active run. The thread itself stays Open and addressable. */
fun createInterruptAgentToolDeclaration(): Tool = Tool(
    name = "interrupt_agent",
    description = """
        Interrupt the active run of a spawned agent thread by its child_thread_id
        or canonical agent path. The thread is preserved (stays Open and
        addressable, e.g. for a later follow-up); only the running turn is
        cancelled. Returns the previous run status; an idle thread returns
        previous_status "idle" without error.
    """.trimIndent(),
    parameters = { interruptAgentParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

/**
 * P1-d: deliver a message to a spawned agent thread without waking it. The
 * message enters the target thread's mailbox but does not trigger a new turn:
 * an idle target's messages stay queued until its next run, and a running
 * target receives them at its next tool-loop boundary. Sending to your own
 * thread or to a thread outside your tree is rejected.
 */
fun createSendMessageToolDeclaration(): Tool = Tool(
    name = "send_message",
    description = """
        Deliver a message to a spawned agent thread (by child_thread_id or
        canonical agent path) without waking it. It does not trigger a new turn:
        an idle target's messages stay in its mailbox until its next run, and a
        running target receives them at its next tool-loop boundary. You cannot
        message your own thread; targets outside your thread tree are rejected.
    """.trimIndent(),
    parameters = { sendMessageParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

/**
 * P1-d: deliver a follow-up task to a spawned agent thread and wake it when
 * idle. Unlike send_message, an idle target starts a new run with the message
 * immediately; a running target queues the message in its mailbox and folds it
 * in at its next tool-loop boundary.
 */
fun createFollowupTaskToolDeclaration(): Tool = Tool(
    name = "followup_task",
    description = """
        Deliver a follow-up task message to a spawned agent thread (by
        child_thread_id or canonical agent path) and wake it. If the target is
        idle (no active run) it starts a new run with the message immediately;
        if it is running, the message is queued in its mailbox and folded in at
        its next tool-loop boundary. You cannot send to your own thread;
        targets outside your thread tree are rejected.
        Optional model_id and reasoning_level select a model from the user's
        subagent model_pool for the next run. Omitting them retains the child's
        current configuration. A running provider request is not restarted by
        a follow-up; the updated configuration applies to a later run.
    """.trimIndent(),
    parameters = { followupTaskParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

/**
 * P1-d: suspend this tool call until this thread's mailbox receives any
 * activity in a background run. Interactive foreground runs yield instead of
 * occupying the conversation while children work. Pending mail returns immediately.
 */
fun createWaitAgentToolDeclaration(): Tool = Tool(
    name = "wait_agent",
    description = """
        Returns immediately when the mailbox already has pending activity.
        A foreground root with no active child runs returns status=no_active_children
        instead of yielding. Read existing reports with session_read, or start a
        followup_task if more work is needed; do not wait for an ended child to
        send a continuation on its own. These are native functions, not mcp_call tools.
        In an interactive foreground conversation, an empty mailbox yields the
        current turn immediately only while child runs remain active. Child agents
        continue running and their reports arrive automatically. Do not loop
        on wait_agent or keep the user waiting for background work.
        In a background run, suspend this tool call until mailbox activity,
        until the wait is interrupted by new user input, or until timeout_ms
        elapses. Background timeout_ms is clamped to [5000, 300000] milliseconds
        and defaults to 30000.
    """.trimIndent(),
    parameters = { waitAgentParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

/**
 * Cross-session conversation read tools (`session_search` + `session_read`).
 * Unlike Android's current-session `conversation_search`/`conversation_expand`,
 * these search and read ALL persisted conversations on this device (titles and
 * message text) — the agent can follow up on another session's past chat.
 * Read-only: no approval, ledger classification is pure. iOS local execution
 * lives in ChatToolRuntime (Swift); `execute` is empty here, same pattern as
 * createSearchWebToolDeclaration. Declared via iosToolDeclaration, deferred
 * (tool_search exposes them) — Android wiring is a follow-up.
 */
fun createSessionSearchToolDeclaration(): Tool = Tool(
    name = "session_search",
    description = """
        Search across ALL conversations (titles and message text) on this device.
        Use when the user references another session/conversation or past chat.
        Returns matching sessions with snippets; follow up with `session_read` to read one.
    """.trimIndent().replace("\n", " "),
    parameters = { sessionSearchParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

fun createSessionReadToolDeclaration(): Tool = Tool(
    name = "session_read",
    description = """
        Read messages of a conversation by id (from session_search or a child report reference). Read-only.
        This is a native iOS tool; call it as `session_read`, never through `mcp_call`. If hidden, call
        `tool_search` first. Without `message_id`, returns recent messages with `message_id`,
        `total_chars`, `truncated`, and `next_offset` metadata. With `message_id`, returns the
        full projected text in pages: pass the returned `next_offset` as `offset` until it is null.
    """.trimIndent().replace("\n", " "),
    parameters = { sessionReadParameters() },
    needsApproval = false,
    execute = { emptyList() }
)

private fun sessionSearchParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("query", buildJsonObject {
            put("type", "string")
            put("description", "Required. Keywords to search across all conversation titles and message text on this device.")
        })
        put("limit", buildJsonObject {
            put("type", "integer")
            put("description", "Optional. Maximum number of matching sessions to return, clamped to [1, 20]; defaults to 8.")
        })
    },
    required = listOf("query"),
)

private fun sessionReadParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("conversation_id", buildJsonObject {
            put("type", "string")
            put("description", "Required. The conversation id (UUID) of a session, taken from session_search results.")
        })
        put("max_messages", buildJsonObject {
            put("type", "integer")
            put("description", "Optional. Maximum number of latest messages to return, clamped to [1, 50]; defaults to 20.")
        })
        put("message_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional. A message_id from a recent-message result or child report reference; selects that persisted message for full-text paging.")
        })
        put("offset", buildJsonObject {
            put("type", "integer")
            put("minimum", 0)
            put("description", "Optional with message_id. Non-negative 0-based Swift character offset; defaults to 0. Continue from next_offset.")
        })
        put("max_chars", buildJsonObject {
            put("type", "integer")
            put("minimum", 1)
            put("maximum", 8_000)
            put("description", "Optional with message_id. Maximum page characters, clamped to [1, 8000]; defaults to 2000. The returned page may be shorter to stay below the tool output limit.")
        })
    },
    required = listOf("conversation_id"),
)

private const val subAgentEnglishNames =
    "Alex, Alice, Anna, Ben, Chloe, Claire, Daniel, David, Ella, Emma, Eric, Eva, " +
    "Grace, Hannah, Henry, Jack, James, Julia, Kate, Leo, Liam, Lily, Lisa, Lucas, " +
    "Lucy, Max, Mia, Nathan, Noah, Nora, Oliver, Oscar, Owen, Rose, Ruby, Sam, " +
    "Sarah, Simon, Sophie, Zoe"

private const val subAgentChineseNames =
    "小明、小华、小林、小雨、小夏、小雪、小宁、小安、小宇、小晨、小月、小星、" +
    "小青、小梅、小兰、小敏、小静、小燕、小芳、小云、小平、小乐、小文、小杰"

private fun spawnAgentParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("model_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional exact configured model UUID from list_agents.model_pool. Omit to let the runtime distribute new child runs across the pool. Do not use a provider's wire model name here.")
        })
        put("reasoning_level", buildJsonObject {
            put("type", "string")
            put("enum", JsonArray(ReasoningLevel.entries.map { JsonPrimitive(it.name.lowercase()) }))
            put("description", "Optional reasoning level supported by the selected pool model; see list_agents.model_pool. Omission uses its configured default, not an unsupported level inherited from another model.")
        })
        put("task_name", buildJsonObject {
            put("type", "string")
            put("pattern", "^[a-z0-9_]+$")
            put("description", "Required. Lowercase letters, digits and underscores only; used for the canonical agent path. For each dynamic agent, the current parent model should choose a short familiar English first name (examples: $subAgentEnglishNames), inspect list_agents when sibling names may already exist, avoid reusing a sibling name, and never add a numeric suffix itself. Keep the name stable for followups and use the returned agent_path. Avoid test labels, arbitrary role codes and task descriptions as names. Put the work in message. Preserve an explicitly user-requested name when it fits the path format; built-in role ids stay unchanged.")
        })
        put("message", buildJsonObject {
            put("type", "string")
            put("description", "Required. The initial task message the spawned agent receives as its NEW_TASK.")
        })
        put("fork_turns", buildJsonObject {
            put("type", "string")
            put("description", "How much of this thread's history the child inherits: \"none\" (empty), \"all\" (full copy), or a positive-integer string N (last N user turns). Defaults to \"all\".")
        })
        put("role_assistant_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional assistant id the child conversation should use.")
        })
        put("role_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional built-in role id (for example explorer, historian, oracle, designer, writer, fixer, browser), or a dynamic role id when dynamic subagents are enabled.")
        })
        put("system_prompt", buildJsonObject {
            put("type", "string")
            put("description", "Optional one-off role instructions. Requires the dynamic subagent setting; with it off, only saved built-in role configuration is allowed.")
        })
        put("context", buildJsonObject {
            put("type", "string")
            put("description", "Optional task-specific context injected into the child system context. Requires dynamic subagents.")
        })
        put("tool_scope", buildJsonObject {
            put("type", "array")
            put("items", buildJsonObject { put("type", "string") })
            put("description", "Optional exact tool names the child may discover and execute. Requires dynamic subagents for one-off scope; with a role, omission uses that role's saved/default scope, otherwise it inherits the parent catalog. An empty array grants no tools.")
        })
        put("skill_names", buildJsonObject {
            put("type", "array")
            put("items", buildJsonObject { put("type", "string") })
            put("description", "Optional installed and enabled skill directory names to load into the child role context. Requires dynamic subagents for one-off selection.")
        })
    },
    required = listOf("task_name", "message"),
)

private fun listAgentsParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("path_prefix", buildJsonObject {
            put("type", "string")
            put("description", "Optional agent path prefix to filter the listed threads (e.g. /root/research).")
        })
    },
)

private fun interruptAgentParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Required. child_thread_id (uuid) or canonical agent path of the agent thread to interrupt.")
        })
    },
    required = listOf("target"),
)

private fun sendMessageParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Required. child_thread_id (uuid) or canonical agent path of the target thread.")
        })
        put("message", buildJsonObject {
            put("type", "string")
            put("description", "Required. The message text to deliver. It does not trigger a new turn; an idle target's messages stay in its mailbox until its next run.")
        })
    },
    required = listOf("target", "message"),
)

private fun followupTaskParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("model_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional exact configured model UUID from list_agents.model_pool for the child's next run. Omission retains the child's selected model.")
        })
        put("reasoning_level", buildJsonObject {
            put("type", "string")
            put("enum", JsonArray(ReasoningLevel.entries.map { JsonPrimitive(it.name.lowercase()) }))
            put("description", "Optional supported reasoning level for the child's next run; omission retains its current configuration.")
        })
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Required. child_thread_id (uuid) or canonical agent path of the target thread.")
        })
        put("message", buildJsonObject {
            put("type", "string")
            put("description", "Required. The follow-up task message. Wakes an idle target into a new run; a running target receives it at its next tool-loop boundary.")
        })
    },
    required = listOf("target", "message"),
)

private fun waitAgentParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("timeout_ms", buildJsonObject {
            put("type", "integer")
            put("description", "Optional maximum wait in milliseconds, clamped to [5000, 300000]; defaults to 30000. The wait ends earlier on mailbox activity or when interrupted by new input.")
        })
    },
)

/**
 * The declaration table behind [iosToolDeclaration]. A map (not a `when`) so
 * the full iOS tool-name list is DERIVED from the real declaration source via
 * [iosToolDeclarationNames] — nothing on the Swift side hand-mirrors these
 * keys anymore. Each entry constructs a fresh `Tool` per invocation, exactly
 * like the old `when` branches did.
 */
private val IOS_TOOL_DECLARATION_PROVIDERS: Map<String, () -> Tool> = mapOf(
    "ask_user" to ::createAskUserToolDeclaration,
    "exec" to ::createExecToolDeclaration,
    "wait" to ::createWaitToolDeclaration,
    "search_web" to ::createSearchWebToolDeclaration,
    "scrape_web" to ::createScrapeWebToolDeclaration,
    "memory_tool" to ::createMemoryToolDeclaration,
    "workspace_file_read" to ::createWorkspaceFileReadToolDeclaration,
    "workspace_file_write" to ::createWorkspaceFileWriteToolDeclaration,
    "workspace_file_edit" to ::createWorkspaceFileEditToolDeclaration,
    "workspace_file_list" to ::createWorkspaceFileListToolDeclaration,
    "workspace_file_search" to ::createWorkspaceFileSearchToolDeclaration,
    "workspace_file_move" to ::createWorkspaceFileMoveToolDeclaration,
    "workspace_artifact_read" to ::createWorkspaceArtifactReadToolDeclaration,
    "workspace_artifact_delete" to ::createWorkspaceArtifactDeleteToolDeclaration,
    "generate_image" to ::createImageGenToolDeclaration,
    "wm_stations" to ::createWebMountStationsToolDeclaration,
    "wm_tab_list" to ::createWebMountTabListToolDeclaration,
    "wm_tab_new" to ::createWebMountTabNewToolDeclaration,
    "wm_tab_close" to ::createWebMountTabCloseToolDeclaration,
    "wm_open" to ::createWebMountOpenToolDeclaration,
    "wm_state" to ::createWebMountStateToolDeclaration,
    "wm_observe" to ::createWebMountObserveToolDeclaration,
    "wm_extract" to ::createWebMountExtractToolDeclaration,
    "wm_get" to ::createWebMountGetToolDeclaration,
    "wm_visual_snapshot" to ::createWebMountVisualSnapshotToolDeclaration,
    "wm_visual_read" to ::createWebMountVisualReadToolDeclaration,
    "wm_screenshot" to ::createWebMountScreenshotToolDeclaration,
    "wm_back" to ::createWebMountBackToolDeclaration,
    "wm_forward" to ::createWebMountForwardToolDeclaration,
    "wm_clear_session" to ::createWebMountClearSessionToolDeclaration,
    "wm_site_add" to ::createWebMountSiteAddToolDeclaration,
    "wm_site_remove" to ::createWebMountSiteRemoveToolDeclaration,
    "wm_click" to ::createWebMountClickToolDeclaration,
    "wm_tap" to ::createWebMountTapToolDeclaration,
    "wm_type" to ::createWebMountTypeToolDeclaration,
    "wm_keys" to ::createWebMountKeysToolDeclaration,
    "wm_scroll" to ::createWebMountScrollToolDeclaration,
    "wm_select" to ::createWebMountSelectToolDeclaration,
    "wm_find" to ::createWebMountFindToolDeclaration,
    "wm_wait" to ::createWebMountWaitToolDeclaration,
    "wm_run_goal" to ::createWebMountRunGoalToolDeclaration,
    "wm_act" to ::createWebMountActToolDeclaration,
    "mcp_call" to ::createMcpCallToolDeclaration,
    "mcp_list" to ::createMcpListToolDeclaration,
    "mcp_test" to ::createMcpTestToolDeclaration,
    "mcp_describe_tool" to ::createMcpDescribeToolDeclaration,
    "mcp_import_from_skill" to ::createMcpImportFromSkillToolDeclaration,
    "skills_list" to ::createSkillsListToolDeclaration,
    "use_skill" to ::createUseSkillToolDeclaration,
    "skill_validate" to ::createSkillValidateToolDeclaration,
    "skill_import" to ::createSkillImportToolDeclaration,
    "soul_import" to ::createSoulImportToolDeclaration,
    "skill_enable" to ::createSkillEnableToolDeclaration,
    "skill_disable" to ::createSkillDisableToolDeclaration,
    "recipes_list" to ::createRecipesListToolDeclaration,
    "recipe_validate" to ::createRecipeValidateToolDeclaration,
    "recipe_import" to ::createRecipeImportToolDeclaration,
    "recipe_enable" to ::createRecipeEnableToolDeclaration,
    "recipe_disable" to ::createRecipeDisableToolDeclaration,
    "recipe_delete" to ::createRecipeDeleteToolDeclaration,
    "plugins_list" to ::createPluginsListToolDeclaration,
    "plugin_sdk" to ::createPluginSdkToolDeclaration,
    "plugin_test" to ::createPluginTestToolDeclaration,
    "plugin_validate" to ::createPluginValidateToolDeclaration,
    "plugin_import" to ::createPluginImportToolDeclaration,
    "plugin_enable" to ::createPluginEnableToolDeclaration,
    "plugin_disable" to ::createPluginDisableToolDeclaration,
    "plugin_delete" to ::createPluginDeleteToolDeclaration,
    "plugin_rollback" to ::createPluginRollbackToolDeclaration,
    "plugin_restore" to ::createPluginRestoreToolDeclaration,
    "plugin_export" to ::createPluginExportToolDeclaration,
    "subagent_dispatch" to ::createSubAgentDispatchToolDeclaration,
    "model_council_run" to ::createModelCouncilRunToolDeclaration,
    "file_read_selected" to ::createSelectedFileReadToolDeclaration,
    "ish_handoff" to ::createIshHandoffToolDeclaration,
    "ios_ish_execute" to ::createIosIshExecuteToolDeclaration,
    "terminal_execute" to ::createTerminalExecuteToolDeclaration,
    "ios_shell_execute" to ::createIosShellExecuteToolDeclaration,
    "terminal_job_start" to ::createTerminalJobStartToolDeclaration,
    "terminal_job_read" to ::createTerminalJobReadToolDeclaration,
    "terminal_job_wait" to ::createTerminalJobWaitToolDeclaration,
    "terminal_job_stop" to ::createTerminalJobStopToolDeclaration,
    "permissions_status" to ::createPermissionsStatusToolDeclaration,
    "runtime_status" to ::createRuntimeStatusToolDeclaration,
    "weather_read" to ::createWeatherReadToolDeclaration,
    "health_summary_read" to ::createHealthSummaryReadToolDeclaration,
    "calendar_events_list" to ::createCalendarEventsListToolDeclaration,
    "calendar_event_create" to ::createCalendarEventCreateToolDeclaration,
    "calendar_event_update" to ::createCalendarEventUpdateToolDeclaration,
    "calendar_event_delete" to ::createCalendarEventDeleteToolDeclaration,
    "reminders_list" to ::createRemindersListToolDeclaration,
    "reminder_create" to ::createReminderCreateToolDeclaration,
    "reminder_update" to ::createReminderUpdateToolDeclaration,
    "reminder_delete" to ::createReminderDeleteToolDeclaration,
    "reminder_complete" to ::createReminderCompleteToolDeclaration,
    "notification_schedule" to ::createNotificationScheduleToolDeclaration,
    "notification_cancel" to ::createNotificationCancelToolDeclaration,
    "alarm_schedule" to ::createAlarmScheduleToolDeclaration,
    "alarms_list" to ::createAlarmsListToolDeclaration,
    "alarm_cancel" to ::createAlarmCancelToolDeclaration,
    "contacts_pick" to ::createContactsPickToolDeclaration,
    "photos_pick" to ::createPhotosPickToolDeclaration,
    "journaling_suggestion_pick" to ::createJournalingSuggestionPickToolDeclaration,
    "workout_plan_preview" to ::createWorkoutPlanPreviewToolDeclaration,
    "workout_schedule" to ::createWorkoutScheduleToolDeclaration,
    "workouts_scheduled_list" to ::createScheduledWorkoutsListToolDeclaration,
    "workout_scheduled_remove" to ::createScheduledWorkoutRemoveToolDeclaration,
    "tools_list" to ::createToolsListToolDeclaration,
    "subagent_report" to ::createSubAgentReportToolDeclaration,
    "spawn_agent" to ::createSpawnAgentToolDeclaration,
    "list_agents" to ::createListAgentsToolDeclaration,
    "interrupt_agent" to ::createInterruptAgentToolDeclaration,
    "send_message" to ::createSendMessageToolDeclaration,
    "followup_task" to ::createFollowupTaskToolDeclaration,
    "wait_agent" to ::createWaitAgentToolDeclaration,
    "session_search" to ::createSessionSearchToolDeclaration,
    "session_read" to ::createSessionReadToolDeclaration,
    "provider_config_status" to ::createProviderConfigStatusToolDeclaration,
    "provider_config_apply" to ::createProviderConfigApplyToolDeclaration,
    "provider_config_create" to ::createProviderConfigCreateToolDeclaration,
    "provider_refresh_models" to ::createProviderRefreshModelsToolDeclaration,
    "settings_set_model_slot" to ::createSettingsSetModelSlotToolDeclaration,
    "theme_pack_status" to ::createThemePackStatusToolDeclaration,
    "theme_pack_import" to ::createThemePackImportToolDeclaration,
)

fun iosToolDeclaration(name: String): Tool? = IOS_TOOL_DECLARATION_PROVIDERS[name]?.invoke()

/** Every tool name [iosToolDeclaration] can declare — the single declaration
 *  list (sorted for determinism). iOS derives its runtime catalog summary
 *  from this instead of hand-mirroring switch keys. */
fun iosToolDeclarationNames(): List<String> = IOS_TOOL_DECLARATION_PROVIDERS.keys.sorted()

fun iosToolDeclarations(names: List<String>): List<Tool> = names.distinct().mapNotNull(::iosToolDeclaration)

/**
 * [Slice 3] Tool declaration for dispatching a sub-agent task.
 *
 * The model calls this with an `objective` describing the delegated task and an
 * optional `roleId`. The iOS chat runtime dispatches it through
 * `SubAgentRunner.runViaEngine`, backed by `IOSAgentToolEngine`, then resumes the
 * stream with the sub-agent's result text as the tool output.
 *
 * NOTE: `execute` returns empty — actual execution lives in the Swift dispatch
 * (same pattern as createSearchWebToolDeclaration, whose real executor is
 * IOSSearchExecutor in Swift).
 */
fun createSubAgentDispatchToolDeclaration(): Tool = Tool(
    name = "subagent_dispatch",
    description = """
        Dispatch a sub-task to a sub-agent that runs in its own isolated context
        with its own system prompt and model. Use when a task should be delegated
        (e.g. research, drafting, code review) rather than done inline. Returns the
        sub-agent's final output as text.
        Provide a clear `objective`; optionally a `role_id` to select a built-in
        sub-agent role (explorer, historian, oracle, designer, writer, fixer), or
        pass `custom_role_prompt` (with optional `custom_role_name` and
        `custom_role_lens`) for a one-off custom role. `tool_scope` narrows the
        sub-agent's tools within the read-only allowlist. `max_turns` (2-8) and
        `output_budget_chars` (4000-24000) budget the run.
    """.trimIndent(),
    parameters = { subAgentDispatchParameters() },
    execute = { emptyList() }
)

/**
 * [Slice 3] Tool declaration for running the model council.
 *
 * The model calls this with an `objective` and (optionally) `max_seats`. The iOS
 * ChatViewModel dispatches to the native iOS Council room runner, then resumes
 * the stream with the council's synthesized result as the tool output.
 */
fun createModelCouncilRunToolDeclaration(): Tool = Tool(
    name = "model_council_run",
    description = """
        Convene a multi-seat model council to deliberate on an `objective` and
        return a synthesized answer. Use when a question benefits from multiple
        models/perspectives debating before answering. Returns the council's
        final synthesized output as text.
        Provide a clear `objective`; optionally `max_seats` to cap participants.
    """.trimIndent(),
    parameters = { modelCouncilRunParameters() },
    execute = { emptyList() }
)

private fun subAgentDispatchParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("objective", buildJsonObject {
            put("type", "string")
            put("description", "the task to delegate to the sub-agent")
        })
        put("role_id", buildJsonObject {
            put("type", "string")
            put("description", "optional built-in sub-agent role id (explorer, historian, oracle, designer, writer, fixer); omit for the default role")
        })
        put("custom_role_name", buildJsonObject {
            put("type", "string")
            put("description", "Display name for a one-off custom role; supply it with custom_role_prompt. Prefer a familiar English first name from: $subAgentEnglishNames. Only when the user prefers Chinese names, choose from: $subAgentChineseNames. Choose different names for agents in the same group. Keep the name short; put the task or specialty in objective/custom_role_lens, not in the name. Avoid test labels and arbitrary role codes. Preserve a name explicitly requested by the user.")
        })
        put("custom_role_lens", buildJsonObject {
            put("type", "string")
            put("description", "optional focus lens or summary for a one-off custom role")
        })
        put("custom_role_prompt", buildJsonObject {
            put("type", "string")
            put("description", "optional system prompt for a one-off custom role; when present a custom role is used instead of role_id")
        })
        put("max_turns", buildJsonObject {
            put("type", "integer")
            put("minimum", 2)
            put("maximum", 8)
            put("description", "optional max engine turns for the sub-agent run; clamped to 2-8 (custom roles default to 4)")
        })
        put("output_budget_chars", buildJsonObject {
            put("type", "integer")
            put("minimum", 4000)
            put("maximum", 24000)
            put("description", "optional output budget in characters; clamped to 4000-24000 (custom roles default to 12000)")
        })
        put("tool_scope", buildJsonObject {
            put("type", "array")
            put("description", "optional list of tool names the sub-agent may use; narrowed within the read-only allowlist")
            put("items", buildJsonObject { put("type", "string") })
        })
    },
    required = listOf("objective")
)

private fun modelCouncilRunParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("objective", buildJsonObject {
            put("type", "string")
            put("description", "the question/objective for the council to deliberate")
        })
        put("max_seats", buildJsonObject {
            put("type", "integer")
            put("minimum", 2)
            put("maximum", 8)
            put("description", "optional cap on non-host council seats (2-8)")
        })
    },
    required = listOf("objective")
)

/**
 * [Slice 3] Generic MCP tool-call declaration. MCP tools are discovered per
 * server (dynamic), but for the chat dispatch we expose a single generic
 * `mcp_call` tool the model can invoke with a `server`, `tool`, and `arguments`
 * object. The iOS ChatViewModel routes it to IOSMcpManager.callTool.
 *
 * (A richer per-tool declaration set can be generated from discovered tools
 * later; this generic form keeps the dispatch closed-loop for Slice 3.)
 */
fun createMcpCallToolDeclaration(): Tool = Tool(
    name = "mcp_call",
    description = """
        Call a tool on a connected MCP (Model Context Protocol) server. Use when
        the user needs an external capability exposed by a configured MCP server
        (filesystem, database, custom API, etc.). Returns the server's tool
        output as text. Provide the `server` name, the `tool` name, and the
        tool's `arguments` as a JSON object.
    """.trimIndent(),
    parameters = { mcpCallParameters() },
    execute = { emptyList() }
)

fun createMcpListToolDeclaration(): Tool = Tool(
    name = "mcp_list",
    description = "List configured MCP servers, enabled state, connection status, and known tool counts. Pass include_tools=true to see callable MCP tool names.",
    parameters = { mcpListParameters() },
    execute = { emptyList() }
)

fun createMcpTestToolDeclaration(): Tool = Tool(
    name = "mcp_test",
    description = "Test one configured MCP server by id or name and refresh its tool list.",
    parameters = { mcpServerLookupParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

fun createMcpDescribeToolDeclaration(): Tool = Tool(
    name = "mcp_describe_tool",
    description = """
        Return the full description and input JSON schema of one discovered MCP
        tool. Call this before `mcp_call` when you need the exact argument names
        and types for a tool's `arguments`.
    """.trimIndent(),
    parameters = { mcpDescribeToolParameters() },
    execute = { emptyList() }
)

fun createMcpImportFromSkillToolDeclaration(): Tool = Tool(
    name = "mcp_import_from_skill",
    description = "Import standard mcp.json from an installed Skill into the global AmberAgent MCP settings. The host asks once unless high-risk auto-approve is on, then rechecks the digest and connectivity before writing.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("skill_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Installed skill name.")
                })
            },
            required = listOf("skill_name")
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

/**
 * Agent provider/model configuration tools (iOS host executes; Swift dispatch).
 * Read is pure; apply requires host approval. Keys never appear in tool results.
 */
fun createProviderConfigStatusToolDeclaration(): Tool = Tool(
    name = "provider_config_status",
    description = """
        Redacted inventory of configured LLM providers and model slots on this device.
        Use before claiming settings are missing: reports enabled flag, whether an API key
        is stored (boolean only), chat model counts, and issues such as unresolved chat model.
        Never returns API keys or tokens.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("provider_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. Filter to one provider UUID.")
                })
                put("provider_name_contains", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. Case-insensitive substring filter on provider display name.")
                })
                put("include_models", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Optional. When true, include up to 20 chat model labels per provider. Defaults to false.")
                })
            },
            required = emptyList()
        )
    },
    needsApproval = false,
    execute = { emptyList() }
)

fun createProviderConfigCreateToolDeclaration(): Tool = Tool(
    name = "provider_config_create",
    description = """
        Create a new user-owned OpenAI-compatible provider shell (brand generic, not a bundled
        brand like MiMo). Requires name and https base_url. Optional api_key and chat_completions_path.
        Host shows an approval card. After create, call provider_refresh_models then
        settings_set_model_slot. Do not invent bundled brands — configure those via provider_config_apply.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Display name for the new provider.")
                })
                put("base_url", buildJsonObject {
                    put("type", "string")
                    put("description", "HTTPS OpenAI-compatible base URL.")
                })
                put("api_key", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional API key. Omit to create a key-less shell.")
                })
                put("chat_completions_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional path, e.g. /chat/completions.")
                })
            },
            required = listOf("name", "base_url")
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

fun createProviderConfigApplyToolDeclaration(): Tool = Tool(
    name = "provider_config_apply",
    description = """
        Apply configuration to one existing LLM provider (enable/name/base URL/API key).
        The host shows an approval card before writing. API keys are stored in the secure
        key store and are never echoed in the tool result. Prefer provider_id when known.
        Do not clear a key unless the user explicitly asked. Cannot create providers — use
        provider_config_create for new OpenAI-compatible shells.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("provider_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Preferred. Provider UUID from provider_config_status.")
                })
                put("provider_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Alternative unique match on display name when provider_id is omitted.")
                })
                put("enabled", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Optional. Enable or disable the provider.")
                })
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. New display name.")
                })
                put("api_key", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. New API key. Omit to leave unchanged. Empty string clears the key (requires approval).")
                })
                put("base_url", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. HTTPS base URL for OpenAI-compatible endpoints.")
                })
                put("chat_completions_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. Chat completions path (e.g. /chat/completions).")
                })
                put("use_response_api", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Optional. OpenAI Responses API flag when supported.")
                })
            },
            required = emptyList()
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

fun createProviderRefreshModelsToolDeclaration(): Tool = Tool(
    name = "provider_refresh_models",
    description = """
        Fetch the remote model catalog for one provider that already has credentials and
        merge chat models into settings (does not delete manual models). Call after a
        successful provider_config_apply when chat_model_count is zero.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("provider_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Preferred. Provider UUID.")
                })
                put("provider_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Alternative unique display-name match.")
                })
                put("mode", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. \"merge\" (default) keeps manual models; \"replace_chat\" replaces chat-typed models only.")
                })
            },
            required = emptyList()
        )
    },
    needsApproval = false,
    execute = { emptyList() }
)

fun createSettingsSetModelSlotToolDeclaration(): Tool = Tool(
    name = "settings_set_model_slot",
    description = """
        Set a fixed model role slot to an already-configured model by UUID or fuzzy model_ref.
        Allowed slots only: chat, assistant_chat, title, ocr, compress, suggestion, image_generation.
        Provider names (e.g. mimo) are not slots. Fails if the reference is ambiguous or the
        model type does not match the slot. Prefer models whose provider has chat_streaming_supported=true.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("slot", buildJsonObject {
                    put("type", "string")
                    put("description", "Required. One of: chat, assistant_chat, title, ocr, compress, suggestion, image_generation.")
                })
                put("model_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. Model UUID from settings/model lists.")
                })
                put("model_ref", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional. Display name or wire model id substring; must uniquely match.")
                })
            },
            required = listOf("slot")
        )
    },
    needsApproval = false,
    execute = { emptyList() }
)

/**
 * Theme pack tools (iOS host executes). Status is a pure catalog; import
 * try-on + persist requires a foreground approval card. Packs may define a
 * complete visual treatment (including per-mode surfaces, gradients, patterns,
 * and chrome geometry) — never list layout, appearance mode, or chat fonts.
 */
fun createThemePackStatusToolDeclaration(): Tool = Tool(
    name = "theme_pack_status",
    description = """
        Read the current Amber theme recipe, any in-progress try-on, installed pack ids,
        and allowed slot/design constraints. Call this before theme_pack_import. Does not change the UI.
        Optionally pass `id` to inspect a base recipe: omit it or use `current` for the currently
        visible theme (including try-on), or use an installed/builtin id returned here. Builtin ids
        sit-terracotta, pi-steel, notion-blue are reserved.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional base recipe id: `current`, or an installed/builtin id from the status response.")
                })
            },
            required = emptyList()
        )
    },
    needsApproval = false,
    execute = { emptyList() }
)

fun createThemePackImportToolDeclaration(): Tool = Tool(
    name = "theme_pack_import",
    description = """
        Propose an Amber theme pack. The host immediately tries on the recipe on the real UI
        without saving; the user taps 套用 to persist or 还原 to revert. Use the optional
        `base_id` to modify an existing recipe. `base_id` may be `current` (the currently visible
        theme, including try-on) or an installed/builtin id from theme_pack_status. With `base_id`,
        every other field is a patch: omitted fields stay unchanged, and design/light/dark/gradient/
        components objects merge recursively. Supplying `patterns`, `gradient.colors`, or
        `gradient.darkColors` replaces that whole array. `null` only clears optional design,
        light/dark palette overrides, gradient, components, or a component property. A saved custom theme keeps its id and cannot
        be changed to another id. The first edit of a builtin derives a new custom id; use that
        returned id or `current` for later edits.
        Without `base_id`, create a new complete recipe and provide all nine fields: `id`,
        `display_name`, `paper`, `accent_hex`, `ink_hex`, `canvas_style`, `brand_mark`,
        `shortcut_icon_style`, and `chrome_typeface`. The `id` must be a new slug and cannot be builtin.
        Use the optional `design` object for separate light and dark palettes, per-mode gradients,
        a patterns array with up to three composable layers, and optional chrome geometry; nested
        design fields may be locally omitted when patching. Component-only patches work on builtin/legacy
        themes without inventing palettes: absent light/dark palettes inherit the existing paper colors.
        Newly supplied palette objects need all five color fields; gradients require both full palettes.
        Do not redesign fields the user did not request.
        Gradient colors and darkColors are separate light/dark ramps with 2...4 hex colors each.
        Palette foreground must keep at least 4.5:1 contrast against background and surface;
        mutedForeground must keep at least 3:1. Allowed paper is paper, neutral, white, pi,
        notion (no immersive). New recipes default canvas_scope to shell; edits keep the existing scope. Use appWide when the user asks
        for the design across the whole app. High-luminance accent_hex needs a dark ink_hex;
        contrast must be at least 3.0. Never claim you changed the theme until the user confirms 套用.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("base_id", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional patch target: `current`, or an installed/builtin id from theme_pack_status. Omit for a new recipe.")
                })
                put("id", buildJsonObject {
                    put("type", "string")
                    put("description", "Create: required new slug, e.g. rain-bookstore, not builtin. Patch: omit to retain the base id; a saved custom base cannot use a different id.")
                })
                put("display_name", buildJsonObject {
                    put("type", "string")
                    put("description", "Human title shown on the theme card, e.g. 雨天书店.")
                })
                put("paper", buildJsonObject {
                    put("type", "string")
                    put("description", "Canvas palette.")
                    put("enum", buildJsonArray {
                        add("paper"); add("neutral"); add("white"); add("pi"); add("notion")
                    })
                })
                put("accent_hex", buildJsonObject {
                    put("type", "string")
                    put("description", "Accent color as #RRGGBB or 0xRRGGBB.")
                })
                put("ink_hex", buildJsonObject {
                    put("type", "string")
                    put("description", "On-accent ink. Dark ink for bright accents; white/cream for dark accents.")
                })
                put("canvas_style", buildJsonObject {
                    put("type", "string")
                    put("description", "Texture overlay.")
                    put("enum", buildJsonArray {
                        add("flat"); add("dotGrid"); add("lineGrid"); add("paperGrain")
                    })
                })
                put("brand_mark", buildJsonObject {
                    put("type", "string")
                    put("description", "Home wordmark treatment.")
                    put("enum", buildJsonArray {
                        add("systemWordmark"); add("paintAMBER"); add("serifWordmark")
                    })
                })
                put("shortcut_icon_style", buildJsonObject {
                    put("type", "string")
                    put("description", "Home shortcut glyph skin.")
                    put("enum", buildJsonArray {
                        add("phosphorFill"); add("pixelSit"); add("systemOutline")
                    })
                })
                put("chrome_typeface", buildJsonObject {
                    put("type", "string")
                    put("description", "Home chrome typeface. Does not change chat body fonts.")
                    put("enum", buildJsonArray {
                        add("system"); add("rounded"); add("serif"); add("monospace")
                    })
                })
                put("canvas_scope", buildJsonObject {
                    put("type", "string")
                    put("description", "Where texture paints. Prefer shell. Default shell.")
                    put("enum", buildJsonArray {
                        add("homeOnly"); add("shell"); add("appWide")
                    })
                })
                put("bubble_chrome", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("standard"); add("soft"); add("crisp") })
                })
                put("glass_chrome", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("standard"); add("quieter"); add("solid") })
                })
                put("empty_art", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("none"); add("character") })
                })
                put("settings_chrome", buildJsonObject {
                    put("type", "boolean")
                    put("description", "When true, Appearance labels follow chrome_typeface.")
                })
                put("launch_brand", buildJsonObject {
                    put("type", "string")
                    put("enum", buildJsonArray { add("none"); add("matchBrand") })
                })
                put("design", themeDesignSchema())
            },
            // New recipes still require the nine fields documented above; the host performs
            // that conditional validation because patches intentionally omit unchanged fields.
            required = emptyList()
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

/** JSON Schema for the optional user-authored visual design layer. */
private fun themeDesignSchema(): JsonObject = buildJsonObject {
    put("type", buildJsonArray { add("object"); add("null") })
    put(
        "description",
        "Optional visual design. For a new recipe, provide complete light/dark palettes and a patterns array (it may be empty). For a patch, any nested field may be omitted and objects merge recursively; null clears the whole design."
    )
    put("properties", buildJsonObject {
        put("light", themeDesignPaletteSchema("Light-mode palette."))
        put("dark", themeDesignPaletteSchema("Dark-mode palette."))
        put("gradient", themeDesignGradientSchema())
        put("patterns", themeDesignPatternsSchema())
        put("components", themeDesignComponentsSchema())
    })
    put("required", buildJsonArray {})
}

private fun themeDesignPaletteSchema(description: String): JsonObject = buildJsonObject {
    put("type", buildJsonArray { add("object"); add("null") })
    put("description", "$description Omit fields in a patch to retain the base value; null removes this override and inherits the paper palette. A newly added palette needs all five colors.")
    put("properties", buildJsonObject {
        put("background", buildJsonObject {
            put("type", "string")
            put("description", "Hex color (#RRGGBB or 0xRRGGBB). Main app background.")
        })
        put("surface", buildJsonObject {
            put("type", "string")
            put("description", "Hex color (#RRGGBB or 0xRRGGBB). Cards, sheets, and controls.")
        })
        put("foreground", buildJsonObject {
            put("type", "string")
            put("description", "Hex color with at least 4.5:1 contrast against background and surface.")
        })
        put("mutedForeground", buildJsonObject {
            put("type", "string")
            put("description", "Hex color with at least 3:1 contrast against background and surface.")
        })
        put("border", buildJsonObject {
            put("type", "string")
            put("description", "Hex color for borders and separators.")
        })
    })
    put("required", buildJsonArray {})
}

private fun themeDesignGradientSchema(): JsonObject = buildJsonObject {
    put("type", buildJsonArray { add("object"); add("null") })
    put("description", "Optional gradient ramps. colors is light mode; darkColors is dark mode. Omit fields to retain them in a patch; null clears the gradient.")
    put("properties", buildJsonObject {
        put("colors", buildJsonObject {
            put("type", "array")
            put("minItems", 2)
            put("maxItems", 4)
            put("description", "Light-mode hex colors, 2...4 stops; in a patch this replaces the whole ramp.")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("darkColors", buildJsonObject {
            put("type", "array")
            put("minItems", 2)
            put("maxItems", 4)
            put("description", "Dark-mode hex colors, 2...4 stops; in a patch this replaces the whole ramp. Keep them readable with the dark palette foreground.")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("angle", buildJsonObject {
            put("type", "number")
            put("description", "Gradient angle in degrees.")
        })
    })
    put("required", buildJsonArray {})
}

private fun themeDesignPatternsSchema(): JsonObject = buildJsonObject {
    put("type", "array")
    put("maxItems", 3)
    put("description", "Composable texture layers; provide an array (possibly empty) with at most 3 complete layers. In a patch, the supplied array replaces all layers.")
    put("items", buildJsonObject {
        put("type", "object")
        put("properties", buildJsonObject {
            put("kind", buildJsonObject {
                put("type", "string")
                put("enum", buildJsonArray {
                    add("dots"); add("grid"); add("diagonal"); add("crosses"); add("waves"); add("rings")
                })
            })
            put("color", buildJsonObject {
                put("type", "string")
                put("description", "Pattern color as #RRGGBB or 0xRRGGBB.")
            })
            put("opacity", buildJsonObject {
                put("type", "number")
                put("minimum", 0)
                put("maximum", 0.3)
                put("description", "Pattern opacity, 0...0.3.")
            })
            put("spacing", buildJsonObject {
                put("type", "number")
                put("minimum", 12)
                put("maximum", 120)
                put("description", "Pattern spacing, 12...120 points.")
            })
            put("size", buildJsonObject {
                put("type", "number")
                put("minimum", 0.5)
                put("maximum", 8)
                put("description", "Pattern stroke/dot size, 0.5...8 points.")
            })
        })
        put("required", buildJsonArray {
            add("kind"); add("color"); add("opacity"); add("spacing"); add("size")
        })
    })
}

private fun themeDesignComponentsSchema(): JsonObject = buildJsonObject {
    put("type", buildJsonArray { add("object"); add("null") })
    put("description", "Optional chrome geometry, brand text, and shadow tuning; every field is optional. Omit a field to retain it in a patch; null clears the component object or property.")
    put("properties", buildJsonObject {
        put("cardRadius", themeDesignComponentNumberSchema("Card corner radius, 0...32 points.", 0, 32))
        put("bubbleRadius", themeDesignComponentNumberSchema("Chat bubble corner radius, 0...28 points.", 0, 28))
        put("controlRadius", themeDesignComponentNumberSchema("Control corner radius, 0...28 points.", 0, 28))
        put("borderWidth", themeDesignComponentNumberSchema("Border width, 0...3 points.", 0, 3))
        put("shadowOpacity", themeDesignComponentNumberSchema("Shadow opacity, 0...0.35.", 0, 0.35))
        put("shadowRadius", themeDesignComponentNumberSchema("Shadow blur radius, 0...24 points.", 0, 24))
        put("brandText", buildJsonObject {
            put("type", buildJsonArray { add("string"); add("null") })
            put("minLength", 1)
            put("maxLength", 16)
            put("description", "Optional custom brand text, 1...16 characters.")
        })
        put("brandSize", themeDesignComponentNumberSchema("Optional brand text size, 20...40 points.", 20, 40))
        put("brandTracking", themeDesignComponentNumberSchema("Optional brand text tracking, -2...6 points.", -2, 6))
    })
}

private fun themeDesignComponentNumberSchema(description: String, minimum: Number, maximum: Number): JsonObject = buildJsonObject {
    put("type", buildJsonArray { add("number"); add("null") })
    put("minimum", minimum)
    put("maximum", maximum)
    put("description", description)
}

/**
 * P0-b: one discovered MCP tool flattened into an independent declaration
 * input. `inputSchema` is the raw `tools/list` JSON schema (nullable — some
 * servers omit it). Swift cannot construct [JsonObject] directly (Kotlin/Native
 * exports it as an opaque NSDictionary), so the secondary constructor parses
 * the raw persisted schema JSON text that IOSMcpTool carries.
 */
@Serializable
data class McpDiscoveredToolSpec(
    val name: String,
    val description: String? = null,
    val inputSchema: JsonObject? = null,
) {
    constructor(name: String, description: String?, inputSchemaJson: String?) : this(
        name = name,
        description = description,
        inputSchema = parseMcpSchemaJson(inputSchemaJson),
    )
}

private fun parseMcpSchemaJson(text: String?): JsonObject? =
    text?.let { runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull() }

/** P0-b: flattened `mcp__{server}__{tool}` name (MCP community / Claude Code
 *  convention). Each part is sanitized (non `[a-zA-Z0-9_-]` → `_`); the whole
 *  name is truncated to 64 chars when overlong — deterministic by construction.
 *  Sanitization is NOT reversible, so execution resolves back to a directory
 *  (see `mcpExpandedToolDeclarations` consumers) instead of parsing strings. */
fun expandedMcpToolName(server: String, tool: String): String {
    val name = "mcp__${sanitizeMcpNamePart(server)}__${sanitizeMcpNamePart(tool)}"
    return if (name.length <= MCP_EXPANDED_MAX_NAME_LENGTH) name else name.take(MCP_EXPANDED_MAX_NAME_LENGTH)
}

/** P0-b: `mcp__` prefix classifies expanded MCP tool calls for routing.
 *  Distinct from the `mcp_call`/`mcp_list`/… management names (single `_`). */
fun isExpandedMcpToolName(name: String): Boolean = name.startsWith(MCP_EXPANDED_PREFIX)

/**
 * P0-b: generate one flattened declaration per discovered tool. Description
 * falls back to "MCP tool {tool} on {server}"; parameters are the normalized
 * input schema; needsApproval/allowsAutoApproval/mandatoryApproval match the
 * `mcp_call` passthrough declaration exactly. Sanitized name collisions within
 * the server keep the first occurrence (never throws). Cross-server collisions
 * (e.g. `srv.1` vs `srv_1`, both sanitizing to `srv_1`) are resolved by the
 * caller: generate per server, then merge keeping the first occurrence.
 */
fun mcpExpandedToolDeclarations(
    serverName: String,
    discovered: List<McpDiscoveredToolSpec>,
): List<Tool> {
    val seenNames = mutableSetOf<String>()
    return discovered.mapNotNull { spec ->
        val name = expandedMcpToolName(serverName, spec.name)
        if (!seenNames.add(name)) return@mapNotNull null
        Tool(
            name = name,
            description = spec.description?.takeIf { it.isNotBlank() }
                ?: "MCP tool ${spec.name} on ${serverName}",
            parameters = { normalizeMcpInputSchema(spec.inputSchema) },
            execute = { emptyList() },
        )
    }
}

/**
 * P0-b: flatten an MCP JSON schema into the amber [InputSchema] shape.
 * Object-like roots (type==object, or no type but `properties` present) keep
 * their `properties` verbatim — `$ref`/`anyOf`/nested schemas pass through
 * untouched (no recursive resolution) — with `required` taken as the string
 * array when present. Non-object roots (array/string/…) are wrapped under an
 * `input` property. null → empty object.
 */
fun normalizeMcpInputSchema(schema: JsonObject?): InputSchema {
    if (schema == null) return InputSchema.Obj(properties = buildJsonObject { })
    val type = (schema["type"] as? JsonPrimitive)?.contentOrNull
    val objectLike = type == "object" || (type == null && schema["properties"] != null)
    if (!objectLike) {
        return InputSchema.Obj(
            properties = buildJsonObject { put("input", schema) },
            required = listOf("input"),
        )
    }
    val properties = schema["properties"] as? JsonObject ?: buildJsonObject { }
    val required = (schema["required"] as? JsonArray)?.let { array ->
        val strings = array.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.contentOrNull }
        if (strings.size == array.size) strings else null
    }
    return InputSchema.Obj(properties = properties, required = required)
}

private const val MCP_EXPANDED_PREFIX = "mcp__"
private const val MCP_EXPANDED_MAX_NAME_LENGTH = 64

private fun sanitizeMcpNamePart(value: String): String = value.map { char ->
    if (char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9' || char == '-' || char == '_') {
        char
    } else {
        '_'
    }
}.joinToString("")

fun createSkillsListToolDeclaration(): Tool = Tool(
    name = "skills_list",
    description = "List AmberAgent skills and their load status. Use this first when you are unsure which skills are installed, enabled, disabled, or missing.",
    parameters = { InputSchema.Obj(properties = buildJsonObject {}) },
    execute = { emptyList() }
)

fun createUseSkillToolDeclaration(): Tool = Tool(
    name = "use_skill",
    description = """
        Load and apply a skill to get specialized instructions or capabilities.
        Call this tool when the user's request matches one of the available skills.
    """.trimIndent(),
    parameters = { useSkillParameters() },
    execute = { emptyList() }
)

fun createSkillValidateToolDeclaration(): Tool = Tool(
    name = "skill_validate",
    description = "Validate an installed skill by name or a /workspace skill folder/SKILL.md before import.",
    parameters = { skillValidateParameters() },
    execute = { emptyList() }
)

fun createSoulImportToolDeclaration(): Tool = Tool(
    name = "soul_import",
    description = """
        Prepare a read-only preview of the fixed file /workspace/SOUL.md to update Amber's core
        instructions. Call this only when the user explicitly asks to update Amber's soul or core
        instructions. The host asks once unless high-risk auto-approve is on, then rechecks hashes
        (CAS) before applying. No path argument is accepted.
    """.trimIndent().replace("\n", " "),
    parameters = { InputSchema.Obj(properties = buildJsonObject {}) },
    needsApproval = true,
    execute = { emptyList() }
)

fun createSkillImportToolDeclaration(): Tool = Tool(
    name = "skill_import",
    description = """
        Prepare a read-only import preview for a skill folder or SKILL.md file under /workspace.
        The host asks once unless high-risk auto-approve is on, then rechecks the previewed base and
        candidate hashes (CAS) before atomically applying the package. New skills are enabled;
        existing skills keep their current enabled state.
    """.trimIndent().replace("\n", " "),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("workspace_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Workspace path to a skill folder or SKILL.md.")
                })
            },
            required = listOf("workspace_path")
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

fun createSkillEnableToolDeclaration(): Tool = Tool(
    name = "skill_enable",
    description = "Enable an installed skill for the current AmberAgent assistant.",
    parameters = { skillNameParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

/**
 * Wave B2: `recipe_import` declaration, mirroring `skill_import`
 * (the host previews the Workspace `recipe.json`, asks once unless high-risk
 * auto-approve is on, then rechecks base/candidate hashes before applying and
 * refreshing the dynamic catalog so the promoted recipe is searchable via
 * `tool_search` as `recipe__<name>` from the next model round). Not in
 * `IOS_RESIDENT_TOOL_NAMES` → default-deferred (discovered via `tool_search`).
 */
private val recipeManifestContract = """
        Recipe file contract: write one standalone JSON object matching `amber.recipe.v1`.
        Required top-level fields are `schema`, `name`, `version`, `description`, `inputs`, `steps`, and `outputs`.
        `inputs` maps each input name to the literal string `string`, `number`, or `boolean` (do not use `{"type":...}`).
        Each step requires `id`, an exact published primitive `tool` name, and an `arguments` object; `timeoutSeconds` is optional.
        A binding must be a complete string such as `${'$'}{input.query}` or `${'$'}{step.list.output.total}`; outputs must bind a step output.
        This is a Recipe manifest, not `plugin.json`: do not wrap it in `manifest` or add top-level `type`, `id`, or `tools` fields.
        Minimal valid example:
        {
          "schema": "amber.recipe.v1",
          "name": "catalog_probe",
          "version": "1.0.0",
          "description": "列出当前工具目录并返回总数。",
          "inputs": {},
          "steps": [{"id": "list", "tool": "tools_list", "arguments": {}}],
          "outputs": {"tool_count": "${'$'}{step.list.output.total}"}
        }
    """.trimIndent()

fun createRecipeImportToolDeclaration(): Tool = Tool(
    name = "recipe_import",
    description = """
        Prepare a read-only import preview for a recipe.json under /workspace (amber.recipe.v1 manifest).
        The host asks once unless high-risk auto-approve is on, then rechecks the previewed base and
        candidate hashes (CAS) before atomically applying the recipe package. The promoted recipe
        becomes searchable via tool_search (recipe__<name>) from the next model round.
        ${recipeManifestContract}
    """.trimIndent(),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("workspace_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Workspace path to a recipe.json manifest.")
                })
            },
            required = listOf("workspace_path")
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

fun createRecipesListToolDeclaration(): Tool = Tool(
    name = "recipes_list",
    description = "List installed Recipes with their version, hash, validation and enabled state.",
    parameters = { InputSchema.Obj(properties = buildJsonObject {}) },
    execute = { emptyList() }
)

fun createRecipeValidateToolDeclaration(): Tool = Tool(
    name = "recipe_validate",
    description = """
        Validate an installed Recipe by name or a recipe.json under /workspace without changing state.
        ${recipeManifestContract}
        Use either `name` or `workspace_path` to identify the file; these are locator arguments, not manifest fields.
    """.trimIndent(),
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("name", buildJsonObject {
                    put("type", "string")
                    put("description", "Installed Recipe name. Use either name or workspace_path.")
                })
                put("workspace_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Workspace path to a recipe.json. Use either workspace_path or name.")
                })
            }
        )
    },
    execute = { emptyList() }
)

private fun recipeLifecycleParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("name", buildJsonObject {
            put("type", "string")
            put("description", "Installed Recipe name.")
        })
        put("expected_hash", buildJsonObject {
            put("type", "string")
            put("description", "Exact package hash returned by recipes_list; prevents changing a newer package.")
        })
    },
    required = listOf("name", "expected_hash")
)

fun createRecipeEnableToolDeclaration(): Tool = Tool(
    name = "recipe_enable",
    description = "Enable an installed Recipe. It becomes searchable as recipe__<name> from the next model round.",
    parameters = { recipeLifecycleParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

fun createRecipeDisableToolDeclaration(): Tool = Tool(
    name = "recipe_disable",
    description = "Disable an installed Recipe without deleting its package. In-flight calls keep their pinned version.",
    parameters = { recipeLifecycleParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

fun createRecipeDeleteToolDeclaration(): Tool = Tool(
    name = "recipe_delete",
    description = "Permanently delete an installed Recipe and its rollback slot after explicit approval.",
    parameters = { recipeLifecycleParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

fun createPluginsListToolDeclaration(): Tool = Tool(
    name = "plugins_list",
    description = "List installed dynamic plugins, their exact hashes, enabled state, tools and derived permissions.",
    parameters = { InputSchema.Obj(properties = buildJsonObject {}) },
    execute = { emptyList() }
)

fun createPluginSdkToolDeclaration(): Tool = Tool(
    name = "plugin_sdk",
    description = "Read the on-device plugin development contract, available runtimes and working examples. Use when the user wants Amber to develop, save or dynamically register a reusable tool: write a Workspace package, plugin_validate, plugin_test, then plugin_import with enable=true after user approval. No desktop build is needed for supported script tools.",
    parameters = { InputSchema.Obj(properties = buildJsonObject {}) },
    execute = { emptyList() }
)

fun createPluginTestToolDeclaration(): Tool = Tool(
    name = "plugin_test",
    description = "Execute one tool from a candidate plugin directory in Workspace through the real plugin runtime, before installation or registration. This is a real execution, not a dry run: side effects keep normal approval. Returns candidate_hash and the result; optionally compares expected_result. Read plugin_sdk first. Test on sample data and pass the returned candidate_hash as expected_candidate_hash when importing.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("workspace_directory", buildJsonObject { put("type", "string") })
                put("tool", buildJsonObject {
                    put("type", "string")
                    put("description", "Tool member name declared in plugin.json, e.g. summarize.")
                })
                put("inputs", buildJsonObject {
                    put("type", "object")
                    put("description", "Arguments matching the candidate tool's input contract.")
                })
                put("expected_result", buildJsonObject {
                    put("description", "Optional exact JSON result to assert. For Recipe handlers, compare the outputs object.")
                })
            },
            required = listOf("workspace_directory", "tool", "inputs")
        )
    },
    needsApproval = true,
    execute = { emptyList() }
)

fun createPluginValidateToolDeclaration(): Tool = Tool(
    name = "plugin_validate",
    description = "Validate an installed amber.plugin.v1 package by id or a package directory under /workspace without changing state. Read plugin_sdk for the exact authoring contract; use plugin_test to check actual behavior before importing.",
    parameters = {
        InputSchema.Obj(properties = buildJsonObject {
            put("id", buildJsonObject { put("type", "string") })
            put("workspace_directory", buildJsonObject {
                put("type", "string")
                put("description", "Directory containing plugin.json and its recipes/scripts/resources, as described by plugin_sdk.")
            })
            put("workspace_path", buildJsonObject {
                put("type", "string")
                put("description", "Path to a .amberplugin archive under /workspace.")
            })
        })
    },
    execute = { emptyList() }
)

fun createPluginImportToolDeclaration(): Tool = Tool(
    name = "plugin_import",
    description = "Preview an amber.plugin.v1 package for explicit user approval. Set enable=true to approve installation and activation together so its tools are available from the next model round. Otherwise new or permission-expanding packages install disabled. Read plugin_sdk, validate and test the candidate first.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("workspace_directory", buildJsonObject {
                    put("type", "string")
                    put("description", "Directory containing plugin.json and its declared resources.")
                })
                put("workspace_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Path to a .amberplugin archive under /workspace.")
                })
                put("enable", buildJsonObject {
                    put("type", "boolean")
                    put("description", "Request installation and activation in the same user approval. Defaults to false.")
                })
                put("expected_candidate_hash", buildJsonObject {
                    put("type", "string")
                    put("description", "Candidate hash returned by plugin_test or plugin_validate; rejects changes since that check.")
                })
            }
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

private fun pluginLifecycleParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("id", buildJsonObject { put("type", "string") })
        put("expected_hash", buildJsonObject {
            put("type", "string")
            put("description", "Exact hash returned by plugins_list.")
        })
    },
    required = listOf("id", "expected_hash")
)

fun createPluginEnableToolDeclaration(): Tool = Tool(
    name = "plugin_enable",
    description = "Enable a validated installed plugin from the next model round.",
    parameters = { pluginLifecycleParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

fun createPluginDisableToolDeclaration(): Tool = Tool(
    name = "plugin_disable",
    description = "Disable a plugin while preserving its package and pinned in-flight calls.",
    parameters = { pluginLifecycleParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

fun createPluginDeleteToolDeclaration(): Tool = Tool(
    name = "plugin_delete",
    description = "Delete an installed plugin and its rollback slot after approval.",
    parameters = { pluginLifecycleParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createPluginRollbackToolDeclaration(): Tool = Tool(
    name = "plugin_rollback",
    description = "Restore the previous plugin package after approval.",
    parameters = { pluginLifecycleParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createPluginRestoreToolDeclaration(): Tool = Tool(
    name = "plugin_restore",
    description = "Clear an automatic plugin quarantine after explicit review, without changing the installed package.",
    parameters = { pluginLifecycleParameters() },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createPluginExportToolDeclaration(): Tool = Tool(
    name = "plugin_export",
    description = "Export an installed plugin as a safe .amberplugin archive in Workspace, preserving verified signature provenance.",
    parameters = {
        InputSchema.Obj(
            properties = buildJsonObject {
                put("id", buildJsonObject { put("type", "string") })
                put("expected_hash", buildJsonObject { put("type", "string") })
                put("workspace_path", buildJsonObject {
                    put("type", "string")
                    put("description", "Optional /workspace/*.amberplugin destination.")
                })
            },
            required = listOf("id", "expected_hash")
        )
    },
    needsApproval = true,
    allowsAutoApproval = false,
    execute = { emptyList() }
)

fun createSkillDisableToolDeclaration(): Tool = Tool(
    name = "skill_disable",
    description = "Disable an installed skill for the current AmberAgent assistant.",
    parameters = { skillNameParameters() },
    needsApproval = true,
    execute = { emptyList() }
)

private fun mcpCallParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("server", buildJsonObject {
            put("type", "string")
            put("description", "the connected MCP server name")
        })
        put("tool", buildJsonObject {
            put("type", "string")
            put("description", "the tool name to call on the server")
        })
        put("arguments", buildJsonObject {
            put("type", "object")
            put("description", "the tool arguments as a JSON object")
        })
    },
    required = listOf("server", "tool")
)

private fun mcpListParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("include_tools", buildJsonObject {
            put("type", "boolean")
            put("description", "Include enabled/disabled tool names for each server. Defaults to true.")
        })
        put("include_schema", buildJsonObject {
            put("type", "boolean")
            put("description", "Include MCP input schemas. Defaults to false.")
        })
    }
)

private fun mcpServerLookupParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("server_id", buildJsonObject {
            put("type", "string")
            put("description", "MCP server id.")
        })
        put("name", buildJsonObject {
            put("type", "string")
            put("description", "MCP server name.")
        })
    }
)

private fun mcpDescribeToolParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("server", buildJsonObject {
            put("type", "string")
            put("description", "the configured MCP server name")
        })
        put("tool", buildJsonObject {
            put("type", "string")
            put("description", "the discovered tool name on that server")
        })
    },
    required = listOf("server", "tool")
)

private fun useSkillParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("name", buildJsonObject {
            put("type", "string")
            put("description", "The name of the skill to use")
        })
        put("path", buildJsonObject {
            put("type", "string")
            put(
                "description",
                "Optional relative path to a file inside the skill directory. Omit to read the default SKILL.md instructions."
            )
        })
    },
    required = listOf("name")
)

private fun skillValidateParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("name", buildJsonObject {
            put("type", "string")
            put("description", "Installed skill name.")
        })
        put("workspace_path", buildJsonObject {
            put("type", "string")
            put("description", "Workspace skill folder or SKILL.md.")
        })
    }
)

private fun skillNameParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("name", buildJsonObject {
            put("type", "string")
            put("description", "Skill name.")
        })
    },
    required = listOf("name")
)

private fun searchWebParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("query", buildJsonObject {
            put("type", "string")
            put("description", "search keyword")
        })
        put("topic", buildJsonObject {
            put("type", "string")
            put("description", "search topic")
            put("enum", buildJsonArray {
                add("general")
                add("news")
                add("market")
                add("technical")
                add("finance")
            })
        })
        put("time_range", buildJsonObject {
            put("type", "string")
            put("description", "recency window for current/news searches")
            put("enum", buildJsonArray {
                add("day")
                add("week")
                add("month")
                add("year")
                add("any")
            })
        })
        put("max_results", buildJsonObject {
            put("type", "integer")
            put("description", "maximum merged results to return")
        })
    },
    required = listOf("query")
)

private fun scrapeWebParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("url", buildJsonObject {
            put("type", "string")
            put("description", "public http/https URL to fetch and extract")
        })
        put("max_chars", buildJsonObject {
            put("type", "integer")
            put("description", "maximum extracted characters to return")
        })
        put("service", buildJsonObject {
            put("type", "string")
            put("description", "optional provider hint; iOS MVP uses safe direct fetch and may ignore unsupported services")
        })
    },
    required = listOf("url")
)

private fun memoryToolParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("action", buildJsonObject {
            put("type", "string")
            put("description", "operation to perform")
            put("enum", buildJsonArray {
                add("list")
                add("read")
                add("search")
                add("query")
                add("status")
                add("create")
                add("edit")
                add("delete")
            })
        })
        put("id", buildJsonObject {
            put("type", "integer")
            put("description", "memory id for edit/delete")
        })
        put("scope", buildJsonObject {
            put("type", "string")
            put("description", "memory scope")
            put("enum", buildJsonArray {
                add("core")
                add("short_term")
                add("long_term")
                add("all")
            })
        })
        put("kind", buildJsonObject {
            put("type", "string")
            put("description", "memory kind")
            put("enum", buildJsonArray {
                add("user")
                add("feedback")
                add("project")
                add("reference")
                add("routine")
                add("note")
            })
        })
        put("content", buildJsonObject {
            put("type", "string")
            put("description", "memory content for create/edit")
        })
        put("pinned", buildJsonObject {
            put("type", "boolean")
            put("description", "whether this memory should sort ahead of ordinary memories")
        })
        put("sourceConversationId", buildJsonObject {
            put("type", "string")
            put("description", "optional source conversation id")
        })
        put("sourceMessageIds", buildJsonObject {
            put("type", "array")
            put("description", "optional source message ids")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("expiresAt", buildJsonObject {
            put("type", "integer")
            put("description", "optional expiration epoch milliseconds")
        })
        put("confidence", buildJsonObject {
            put("type", "number")
            put("description", "confidence from 0 to 1")
        })
    },
    required = listOf("action")
)

private fun workspaceFileReadParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("file_id", buildJsonObject {
            put("type", "string")
            put("description", "Workspace file id returned by Workspace, optional when `path` is provided")
        })
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "Workspace path such as /workspace/uploads/example.md, optional when `file_id` is provided")
        })
        put("max_chars", buildJsonObject {
            put("type", "integer")
            put("description", "maximum text characters to return")
        })
        put("start_line", buildJsonObject {
            put("type", "integer")
            put("description", "optional 1-based inclusive first line; when set, reads the original UTF-8 file")
        })
        put("end_line", buildJsonObject {
            put("type", "integer")
            put("description", "optional 1-based inclusive last line; defaults to the end of the file when omitted")
        })
    }
)

private fun workspaceFileWriteParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "target path under /workspace, for example /workspace/notes/summary.md")
        })
        put("content", buildJsonObject {
            put("type", "string")
            put("description", "UTF-8 text or Markdown content to write")
        })
        put("overwrite", buildJsonObject {
            put("type", "boolean")
            put("description", "set true to replace an existing Workspace file")
        })
    },
    required = listOf("path", "content")
)

private fun workspaceFileEditParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("file_id", buildJsonObject {
            put("type", "string")
            put("description", "Workspace file id; optional when `path` is provided")
        })
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "Workspace path such as /workspace/notes/summary.md")
        })
        put("find", buildJsonObject {
            put("type", "string")
            put("minLength", 1)
            put("description", "Exact original text, including whitespace and newlines. Include enough context to match uniquely.")
        })
        put("replace", buildJsonObject {
            put("type", "string")
            put("description", "Replacement text; an empty string deletes the matched text.")
        })
        put("replace_all", buildJsonObject {
            put("type", "boolean")
            put("default", false)
            put("description", "Default false requires exactly one match. Set true only to replace every exact occurrence intentionally.")
        })
    },
    required = listOf("find", "replace")
)

private fun workspaceFileListParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "Optional Workspace path prefix")
        })
        put("limit", buildJsonObject {
            put("type", "integer")
            put("description", "Maximum files to return")
        })
    }
)

private fun workspaceFileSearchParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("query", buildJsonObject {
            put("type", "string")
            put("description", "Text to search for in Workspace file previews")
        })
        put("limit", buildJsonObject {
            put("type", "integer")
            put("description", "Maximum matches to return")
        })
    },
    required = listOf("query")
)

private fun workspaceFileMoveParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("file_id", buildJsonObject {
            put("type", "string")
            put("description", "Workspace file id; optional when `path` is provided")
        })
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "Current Workspace path")
        })
        put("destination_path", buildJsonObject {
            put("type", "string")
            put("description", "Destination Workspace path")
        })
    },
    required = listOf("destination_path")
)

private fun workspaceArtifactReadParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("artifact_id", buildJsonObject {
            put("type", "string")
            put("description", "Workspace artifact id")
        })
        put("id", buildJsonObject {
            put("type", "string")
            put("description", "alias for artifact_id")
        })
    }
)

private fun imageGenParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("prompt", buildJsonObject {
            put("type", "string")
            put("description", "Detailed image prompt. Include subject, style, composition, lighting, and mood.")
        })
        put("aspect_ratio", buildJsonObject {
            put("type", "string")
            put("description", "Image aspect ratio.")
            put("enum", buildJsonArray {
                add("1:1")
                add("16:9")
                add("9:16")
            })
        })
        put("count", buildJsonObject {
            put("type", "integer")
            put("minimum", 1)
            put("maximum", 4)
            put("description", "Number of variants to generate, 1-4. Default 1.")
        })
        put("style", buildJsonObject {
            put("type", "string")
            put("description", "Optional style hint, for example photo, watercolor, poster, or product mockup.")
        })
        put("use_attached_image", buildJsonObject {
            put("type", "boolean")
            put(
                "description",
                "Set true when the latest user-attached chat image should be used as the Codex image2 reference/pad image for style transfer, remakes, or edits. The host injects that attachment; do not paste base64 into this tool call."
            )
        })
        put("source_image_url", buildJsonObject {
            put("type", "string")
            put(
                "description",
                "Optional explicit reference image URL (amber-image-generation://, file://, https://, or data:). Prefer use_attached_image=true for the latest user attachment. Values attached/latest mean the same as use_attached_image=true."
            )
        })
    },
    required = listOf("prompt")
)

private fun ishHandoffParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("command", buildJsonObject {
            put("type", "string")
            put("description", "Single shell command to run in iSH. Use either command or script.")
        })
        put("script", buildJsonObject {
            put("type", "string")
            put("description", "Full POSIX /bin/sh script content to paste into iSH. Use either script or command.")
        })
        put("filename", buildJsonObject {
            put("type", "string")
            put("description", "Optional safe .sh filename to use in iSH and AmberAgent handoff storage.")
        })
        put("purpose", buildJsonObject {
            put("type", "string")
            put("description", "Short user-facing reason for this iSH handoff.")
        })
    }
)

private fun iosIshExecuteParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("command", buildJsonObject {
            put("type", "string")
            put("maxLength", 32000)
            put("description", "Single POSIX shell command to execute with /bin/sh -lc. Use either command or script, not both.")
        })
        put("script", buildJsonObject {
            put("type", "string")
            put("maxLength", 32000)
            put("description", "Full POSIX /bin/sh script content to execute. Use either script or command, not both.")
        })
        put("background", buildJsonObject {
            put("type", "boolean")
            put("description", "Optional. When true, start a process-local asynchronous non-PTY job and return job_id. Defaults to false. This does not grant stdin or durable iOS background execution.")
        })
        put("timeout_seconds", buildJsonObject {
            put("type", "integer")
            put("minimum", 1)
            put("maximum", 3600)
            put("description", "Execution timeout in seconds. Foreground default 60 and maximum 180; background default 900 and maximum 3600.")
        })
        put("purpose", buildJsonObject {
            put("type", "string")
            put("description", "Short user-facing reason for this embedded iSH execution.")
        })
        put("cwd", buildJsonObject {
            put("type", "string")
            put("description", "Optional absolute POSIX working directory inside embedded iSH. Defaults to /workspace.")
        })
    }
)

private fun terminalExecuteParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("command", buildJsonObject {
            put("type", "string")
            put("description", "Required. One bounded shell command to execute on the Remote SSH host without a PTY.")
        })
        put("profile_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional SSH profile UUID. Omit to use AmberAgent's selected default SSH profile.")
        })
        put("timeout_seconds", buildJsonObject {
            put("type", "integer")
            put("minimum", 1)
            put("maximum", 180)
            put("description", "Optional foreground execution timeout in seconds. Default 60, maximum 180.")
        })
        put("purpose", buildJsonObject {
            put("type", "string")
            put("description", "Optional short user-facing reason for this Remote SSH command.")
        })
        put("cwd", buildJsonObject {
            put("type", "string")
            put("description", "Optional absolute POSIX working directory on the Remote SSH host. Omit to use the SSH account default directory.")
        })
    },
    required = listOf("command")
)

private fun iosShellExecuteParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("command", buildJsonObject {
            put("type", "string")
            put("maxLength", 4096)
            put("description", "Required. One bounded AmberShell file or text command under /workspace. The stable target also supports restricted python -c snippets. Supports at most three pipeline stages, <, >, 2> redirection, and fixed PWD/HOME/LANG expansion; no general shell expansion or control flow.")
        })
        put("stdin", buildJsonObject {
            put("type", "string")
            // JSON Schema's maxLength counts Unicode characters, not the UTF-8
            // bytes consumed by AmberShell. Keep this limit in prose so a
            // provider cannot advertise a different unit than the executor.
            put("description", "Optional standard input text. UTF-8 encoded input must not exceed 65536 bytes.")
        })
        put("timeout_seconds", buildJsonObject {
            put("type", "integer")
            put("minimum", 1)
            put("maximum", 180)
            put("description", "Optional foreground timeout/cancellation request in seconds. Default 60; accepted range 1-180.")
        })
        put("purpose", buildJsonObject {
            put("type", "string")
            put("description", "Optional short user-facing reason for this AmberShell command.")
        })
        put("cwd", buildJsonObject {
            put("type", "string")
            put("description", "Optional AmberShell virtual working directory. This phase accepts only /workspace.")
        })
    },
    required = listOf("command")
)

private fun terminalJobStartParameters(): InputSchema = terminalExecuteParameters()

private fun terminalJobIdParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("job_id", buildJsonObject {
            put("type", "string")
            put("description", "Required opaque job handle returned by terminal_job_start.")
        })
    },
    required = listOf("job_id")
)

private fun terminalJobWaitParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("job_id", buildJsonObject {
            put("type", "string")
            put("description", "Required opaque job handle returned by terminal_job_start.")
        })
        put("wait_timeout_seconds", buildJsonObject {
            put("type", "integer")
            put("minimum", 1)
            put("maximum", 30)
            put("description", "Optional observer wait. Default 10 seconds; timeout does not stop the underlying job.")
        })
    },
    required = listOf("job_id")
)

private fun webMountTool(
    name: String,
    description: String,
    parameters: InputSchema,
    needsApproval: Boolean = false
): Tool = Tool(
    name = name,
    description = description,
    parameters = { parameters },
    needsApproval = needsApproval,
    allowsAutoApproval = !needsApproval,
    mandatoryApproval = needsApproval,
    execute = { emptyList() }
)

private fun workspaceTool(
    name: String,
    description: String,
    parameters: InputSchema
): Tool = Tool(
    name = name,
    description = description,
    parameters = { parameters },
    needsApproval = true,
    allowsAutoApproval = false,
    mandatoryApproval = true,
    execute = { emptyList() }
)

private fun emptyObjectParameters(): InputSchema = InputSchema.Obj(properties = buildJsonObject { })

private fun askUserParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("question", buildJsonObject {
            put("type", "string")
            put("description", "The focused question to present inline to the user.")
        })
        put("options", buildJsonObject {
            put("type", "array")
            put("description", "Two to six suggested answers, or an empty array for free text.")
            put("items", buildJsonObject { put("type", "string") })
            put("maxItems", 6)
        })
    },
    required = listOf("question", "options")
)

private fun novelRenameProjectParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("title", buildJsonObject {
            put("type", "string")
            put("description", "The new project name")
        })
        put("reason", buildJsonObject {
            put("type", "string")
            put("description", "Optional short note the user gave for the rename")
        })
    },
    required = listOf("title")
)

private fun novelSetPolishPreferenceParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("preference", buildJsonObject {
            put("type", "string")
            put("description", "The polish preference text; pass an empty string to clear it")
        })
    },
    required = listOf("preference")
)

private fun novelUpsertUpcomingArcParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("beats", buildJsonObject {
            put("type", "array")
            put("description", "Upcoming-arc beat notes; at most 8 beats, each at most 160 characters")
            put("items", buildJsonObject { put("type", "string") })
            put("maxItems", 8)
        })
    },
    required = listOf("beats")
)

private fun novelReviseMaterialParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("material_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional existing material id; when present the material is updated and its kind must match")
        })
        put("kind", buildJsonObject {
            put("type", "string")
            put("description", "Material category")
            put("enum", buildJsonArray {
                add("world")
                add("character")
                add("relationship")
                add("masterOutline")
                add("writingRequirements")
                add("custom")
            })
        })
        put("title", buildJsonObject {
            put("type", "string")
            put("description", "Material title")
        })
        put("content", buildJsonObject {
            put("type", "string")
            put("description", "Material body text")
        })
        put("aliases", buildJsonObject {
            put("type", "array")
            put("description", "Optional aliases for character materials only")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("custom_name", buildJsonObject {
            put("type", "string")
            put("description", "Display name used only when creating a kind=custom material; ignored on update (the existing name is kept)")
        })
    },
    required = listOf("kind", "title", "content")
)

private fun novelSetChapterTitleParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("title", buildJsonObject {
            put("type", "string")
            put("description", "New chapter title; prefer a concise 1–8 character evocative title")
        })
        put("chapter_ordinal", buildJsonObject {
            put("type", "integer")
            put("description", "Optional 1-based index of the working chapter to rename; defaults to the last chapter")
            put("minimum", 1)
        })
        put("chapter_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional chapter UUID; when set, overrides chapter_ordinal")
        })
    },
    required = listOf("title")
)

private fun novelWorkspacePrefixParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("prefix", buildJsonObject {
            put("type", "string")
            put("description", "Optional subdirectory prefix such as setting/characters")
        })
    }
)

private fun novelWorkspacePathParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "Workspace-relative path from novel_workspace_list")
        })
    },
    required = listOf("path")
)

private fun novelWorkspaceGrepParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("query", buildJsonObject {
            put("type", "string")
            put("description", "Substring to search for")
        })
        put("prefix", buildJsonObject {
            put("type", "string")
            put("description", "Optional subdirectory prefix")
        })
    },
    required = listOf("query")
)

private fun novelWorkspaceWriteParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("path", buildJsonObject {
            put("type", "string")
            put("description", "Workspace-relative path to write")
        })
        put("content", buildJsonObject {
            put("type", "string")
            put("description", "New file body")
        })
        put("reason", buildJsonObject {
            put("type", "string")
            put("description", "Optional short note shown on the approval card")
        })
    },
    required = listOf("path", "content")
)

private fun novelReadChapterParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("chapter_ordinal", buildJsonObject {
            put("type", "integer")
            put("description", "Optional 1-based index of the working chapter to read; defaults to the last chapter")
            put("minimum", 1)
        })
        put("chapter_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional chapter UUID; when set, overrides chapter_ordinal")
        })
        put("start_paragraph", buildJsonObject {
            put("type", "integer")
            put("description", "Optional 1-based first paragraph to include")
            put("minimum", 1)
        })
        put("end_paragraph", buildJsonObject {
            put("type", "integer")
            put("description", "Optional 1-based last paragraph to include (inclusive)")
            put("minimum", 1)
        })
    }
)

private fun novelReviseChapterParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("chapter_ordinal", buildJsonObject {
            put("type", "integer")
            put("description", "Optional 1-based index of the working chapter to revise; defaults to the last chapter")
            put("minimum", 1)
        })
        put("chapter_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional chapter UUID; when set, overrides chapter_ordinal")
        })
        put("start_paragraph", buildJsonObject {
            put("type", "integer")
            put("description", "1-based first paragraph to replace")
            put("minimum", 1)
        })
        put("end_paragraph", buildJsonObject {
            put("type", "integer")
            put("description", "1-based last paragraph to replace (inclusive)")
            put("minimum", 1)
        })
        put("new_text", buildJsonObject {
            put("type", "string")
            put("description", "Replacement prose for the selected paragraph range")
        })
        put("reason", buildJsonObject {
            put("type", "string")
            put("description", "Optional short note shown on the approval card")
        })
    },
    required = listOf("start_paragraph", "end_paragraph", "new_text")
)

private fun novelRevertRecentChaptersParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("chapter_count", buildJsonObject {
            put("type", "integer")
            put("description", "Number of most recent working chapters to revert (1-64)")
            put("minimum", 1)
            put("maximum", 64)
        })
        put("reason", buildJsonObject {
            put("type", "string")
            put("description", "Optional short note shown on the approval card")
        })
    },
    required = listOf("chapter_count")
)

private fun novelDeleteChaptersParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("chapter_ordinals", buildJsonObject {
            put("type", "array")
            put("description", "1-based working-manuscript ordinals to remove, including middle chapters")
            put("items", buildJsonObject {
                put("type", "integer")
                put("minimum", 1)
            })
            put("minItems", 1)
            put("maxItems", 64)
        })
        put("chapter_ids", buildJsonObject {
            put("type", "array")
            put("description", "Working chapter UUIDs to remove; combined with chapter_ordinals when both are set")
            put("items", buildJsonObject { put("type", "string") })
            put("minItems", 1)
            put("maxItems", 64)
        })
        put("reason", buildJsonObject {
            put("type", "string")
            put("description", "Optional short note shown on the approval card")
        })
    }
)

private fun novelRejectSettingProposalsParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("proposal_ids", buildJsonObject {
            put("type", "array")
            put("description", "UUIDs to reject; omit or empty to reject every active proposal")
            put("items", buildJsonObject { put("type", "string") })
        })
    },
    required = emptyList()
)

private fun novelProposeChapterPlanParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("outline_placement", buildJsonObject {
            put("type", "string")
            put("description", "Short placement note such as \"第 3 章 · 中段转折\"")
        })
        put("goal_and_conflict", buildJsonObject {
            put("type", "string")
            put("description", "The chapter's goal and conflict (required, non-empty)")
        })
        put("must_happen", buildJsonObject {
            put("type", "array")
            put("description", "Beat items that must happen this chapter; may be empty")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("must_not_happen", buildJsonObject {
            put("type", "array")
            put("description", "Beat items that must not happen this chapter; may be empty")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("ending_hook", buildJsonObject {
            put("type", "string")
            put("description", "The chapter's ending hook; may be an empty string")
        })
        put("visible_facts", buildJsonObject {
            put("type", "array")
            put("description", "Facts the POV is allowed to know in this chapter; may be empty")
            put("items", buildJsonObject { put("type", "string") })
        })
    },
    required = listOf(
        "outline_placement", "goal_and_conflict", "must_happen",
        "must_not_happen", "ending_hook", "visible_facts"
    )
)

private fun novelPrepareGhostwriteParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("outline_placement", buildJsonObject {
            put("type", "string")
            put("description", "Short placement note such as \"第 3 章 · 中段转折\"")
        })
        put("goal_and_conflict", buildJsonObject {
            put("type", "string")
            put("description", "The chapter's goal and conflict (required, non-empty)")
        })
        put("must_happen", buildJsonObject {
            put("type", "array")
            put("description", "Beat items that must happen in the first chapter; at least one")
            put("items", buildJsonObject { put("type", "string") })
            put("minItems", 1)
            put("maxItems", 32)
        })
        put("must_not_happen", buildJsonObject {
            put("type", "array")
            put("description", "Beat items that must not happen in the first chapter; may be empty")
            put("items", buildJsonObject { put("type", "string") })
            put("maxItems", 32)
        })
        put("ending_hook", buildJsonObject {
            put("type", "string")
            put("description", "The first chapter's ending hook; may be an empty string")
        })
        put("visible_facts", buildJsonObject {
            put("type", "array")
            put("description", "Facts the POV is allowed to know in the first chapter; may be empty")
            put("items", buildJsonObject { put("type", "string") })
            put("maxItems", 32)
        })
        put("upcoming_arc", buildJsonObject {
            put("type", "array")
            put("description", "0-8 short soft-direction beats for the chapters after the first; use an empty array when no reliable direction is settled")
            put("items", buildJsonObject { put("type", "string") })
            put("maxItems", 8)
        })
        put("suggested_chapter_count", buildJsonObject {
            put("type", "integer")
            put("description", "Suggested batch size; the author can change it on the approval card")
            put("minimum", 1)
            put("maximum", 10)
        })
        put("reason", buildJsonObject {
            put("type", "string")
            put("description", "Optional short summary of why this direction fits the discussion")
        })
    },
    required = listOf(
        "outline_placement", "goal_and_conflict", "must_happen", "must_not_happen",
        "ending_hook", "visible_facts", "upcoming_arc", "suggested_chapter_count"
    )
)

private fun webMountStationsParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("auth_kind_filter", buildJsonObject {
            put("type", "string")
            put("description", "optional filter: anonymous, cookie, or oauth")
            put("enum", buildJsonArray {
                add("anonymous")
                add("cookie")
                add("oauth")
            })
        })
    }
)

private fun JsonObjectBuilder.putWebMountSessionId(required: Boolean = false) {
    put("session_id", buildJsonObject {
        put("type", "string")
        put(
            "description",
            if (required) {
                "Required for agent mutations. Bind to the session_id returned by wm_tab_list or wm_tab_new; omitted or mismatched session ids are rejected."
            } else {
                "Optional for compatibility. Agent runs must provide a session id returned by wm_tab_list or wm_tab_new; only direct in-app user operations may omit it to address the current foreground session. The executor rejects an omitted agent session id."
            }
        )
    })
}

private fun JsonObjectBuilder.putWebMountSnapshotId(required: Boolean = false) {
    put("snapshot_id", buildJsonObject {
        put("type", "string")
        put(
            "description",
            if (required) {
                "Required for agent mutations. Bind to the snapshot_id returned by wm_observe or wm_find; stale snapshots fail instead of guessing a target."
            } else {
                "optional snapshot id from wm_observe/wm_find; stale snapshots fail instead of guessing a target"
            }
        )
    })
}

private fun JsonObjectBuilder.putWebMountPostcondition() {
    put("postcondition", buildJsonObject {
        put("type", "object")
        put("description", "Optional outcome to wait for after dispatch. Read dispatched, page_changed and goal_verified separately; ok=true alone does not prove the goal. A failed wait does not undo the action: inspect final_observation and retry risk before repeating it. Set require_page_change=true when the outcome must follow a document, URL, or DOM change; ready_state and dom_stable only report readiness and cannot verify the action goal.")
        put("properties", buildJsonObject {
            put("condition", buildJsonObject {
                put("type", "string")
                put("enum", buildJsonArray {
                    add("selector")
                    add("text")
                    add("url_contains")
                    add("ready_state")
                    add("dom_stable")
                    add("document_changed")
                    add("url_changed")
                })
            })
            put("require_page_change", buildJsonObject {
                put("type", "boolean")
                put("description", "Require the postcondition to be observed after the page document, URL, or DOM revision changes; the executor captures the before identity and does not blindly retry an ambiguous action.")
            })
            put("value", buildJsonObject {
                put("type", "string")
                put("minLength", 1)
                put("description", "Non-empty expected selector, text, URL fragment, or ready state. Required for selector, text, url_contains, and ready_state; omit this field for dom_stable, document_changed, and url_changed.")
            })
            put("timeout_ms", buildJsonObject {
                put("type", "integer")
                put("description", "Bounded wait in milliseconds, clamped to 100...30000. Defaults to 5000.")
            })
        })
        put("required", buildJsonArray { add("condition") })
        put("additionalProperties", false)
    })
}

private fun webMountSessionParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
    }
)

private fun webMountObserveParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
        put("max_chars", buildJsonObject {
            put("type", "integer")
            put("minimum", 0)
            put("maximum", 8_000)
            put("description", "Maximum visible text characters to return; clamped by iOS.")
        })
        put("max_links", buildJsonObject {
            put("type", "integer")
            put("minimum", 0)
            put("maximum", 40)
            put("description", "Maximum links to return; clamped by iOS.")
        })
    }
)

private fun webMountVisualReadParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId(required = true)
        put("question", buildJsonObject {
            put("type", "string")
            put("description", "Optional visual verification target, such as whether the iCloud login form is visible or which button is currently shown.")
        })
    },
    required = listOf("session_id")
)

private fun webMountTabNewParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("backend", buildJsonObject {
            put("type", "string")
            put("description", "Optional browser backend; defaults to local. Desktop backends require mcp_server_name.")
            put("enum", buildJsonArray {
                add("local")
                add("moli")
                add("playwright_mcp")
                add("steel")
            })
            put("default", "local")
        })
        put("mcp_server_name", buildJsonObject {
            put("type", "string")
            put("description", "Required when backend is moli, playwright_mcp, or steel; names the MCP server used by the desktop backend.")
        })
        put("site_id", buildJsonObject {
            put("type", "string")
            put("description", "optional station id to associate with the new session")
        })
        put("persistent", buildJsonObject {
            put("type", "boolean")
            put("description", "optional; persist only logical session metadata across app restarts and restore a fresh WebView that must be reopened, never DOM state or actions")
        })
    }
)

private fun webMountTabCloseParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
    }
)

private fun webMountOpenParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
        put("site_id", buildJsonObject {
            put("type", "string")
            put("description", "optional station id from wm_stations, e.g. github")
        })
        put("url", buildJsonObject {
            put("type", "string")
            put("description", "optional web URL; normally must match the WebMount allowlist, while high-risk auto-approve permits unlisted public hosts")
        })
        put("timeout_ms", buildJsonObject {
            put("type", "integer")
            put("description", "load timeout in milliseconds, clamped by iOS")
        })
    }
)

private fun webMountExtractParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
        put("mode", buildJsonObject {
            put("type", "string")
            put("description", "readable text, interactive element summary, or snapshot")
            put("enum", buildJsonArray {
                add("readable")
                add("interactive")
                add("snapshot")
            })
        })
        put("max_chars", buildJsonObject {
            put("type", "integer")
            put("description", "maximum text characters to return")
        })
        put("max_links", buildJsonObject {
            put("type", "integer")
            put("description", "maximum links to return")
        })
    }
)

private fun webMountGetParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
        putWebMountSnapshotId()
        put("selector", buildJsonObject {
            put("type", "string")
            put("description", "Optional CSS selector to read for direct user actions; when target is supplied, omit selector or provide the same value. Agent calls should use target.")
        })
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Preferred target ref from the latest wm_observe/wm_find result; if selector is also supplied, target takes precedence when both values agree and conflicting values are rejected.")
        })
        put("kind", buildJsonObject {
            put("type", "string")
            put("description", "value to read from the target")
            put("enum", buildJsonArray {
                add("text")
                add("value")
                add("attr")
            })
        })
        put("attr_name", buildJsonObject {
            put("type", "string")
            put("description", "attribute name when kind is attr")
        })
        put("max_chars", buildJsonObject {
            put("type", "integer")
            put("description", "maximum characters to return")
        })
    }
)

private fun webMountClearSessionParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("site_id", buildJsonObject {
            put("type", "string")
            put("description", "station id from wm_stations")
        })
    },
    required = listOf("site_id")
)

private fun webMountSiteAddParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("display_name", buildJsonObject {
            put("type", "string")
            put("description", "station display name")
        })
        put("name", buildJsonObject {
            put("type", "string")
            put("description", "alias for display_name")
        })
        put("homepage_url", buildJsonObject {
            put("type", "string")
            put("description", "http(s) homepage URL for the station")
        })
        put("url", buildJsonObject {
            put("type", "string")
            put("description", "alias for homepage_url")
        })
        put("needs_login", buildJsonObject {
            put("type", "boolean")
            put("description", "whether the site should be treated as cookie-login based")
        })
        put("login_cookie_name", buildJsonObject {
            put("type", "string")
            put("description", "optional cookie name hint; values are never exposed")
        })
        put("enabled", buildJsonObject {
            put("type", "boolean")
            put("description", "whether to enable the station immediately; defaults to true after approval")
        })
    }
)

private fun webMountSiteRemoveParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("site_id", buildJsonObject {
            put("type", "string")
            put("description", "station id from wm_stations")
        })
    },
    required = listOf("site_id")
)

private fun webMountTargetParameters(
    includeCoordinates: Boolean = false,
    requireSessionSnapshot: Boolean = false,
    includeClickCount: Boolean = false
): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId(required = requireSessionSnapshot)
        putWebMountSnapshotId(required = requireSessionSnapshot)
        putWebMountPostcondition()
        put("selector", buildJsonObject {
            put("type", "string")
            put("description", "Optional CSS selector for direct user actions; when target is supplied, omit selector or provide the same value. Agent calls should use target.")
        })
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Preferred target ref from the latest wm_observe/wm_extract/wm_find result; required for Agent mutations. If selector is also supplied, target takes precedence when both values agree; conflicting values are rejected.")
        })
        if (includeClickCount) {
            put("click_count", buildJsonObject {
                put("type", "integer")
                put("enum", buildJsonArray { add(1); add(2) })
                put("description", "1 (default) for single-click; 2 for double-click on the same target")
            })
        }
        if (includeCoordinates) {
            put("x", buildJsonObject {
                put("type", "number")
                put("description", "X coordinate in viewport pixels")
            })
            put("y", buildJsonObject {
                put("type", "number")
                put("description", "Y coordinate in viewport pixels")
            })
        }
    },
    required = if (requireSessionSnapshot) listOf("session_id", "snapshot_id") else null
)

private fun webMountTextInteractionParameters(requireSessionSnapshot: Boolean = false): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId(required = requireSessionSnapshot)
        putWebMountSnapshotId(required = requireSessionSnapshot)
        putWebMountPostcondition()
        put("selector", buildJsonObject {
            put("type", "string")
            put("description", "Optional CSS selector for direct user actions; when target is supplied, omit selector or provide the same value. Agent calls should use target.")
        })
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Preferred target ref from the latest wm_observe/wm_extract/wm_find result; required for Agent mutations. If selector is also supplied, target takes precedence when both values agree; conflicting values are rejected.")
        })
        put("text", buildJsonObject {
            put("type", "string")
            put("description", "Text, keys, or option value to send")
        })
        put("value", buildJsonObject {
            put("type", "string")
            put("description", "Alias for text when selecting or typing a value")
        })
    },
    required = if (requireSessionSnapshot) listOf("session_id", "snapshot_id") else null
)

private fun webMountScrollParameters(requireSessionSnapshot: Boolean = false): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId(required = requireSessionSnapshot)
        putWebMountSnapshotId(required = requireSessionSnapshot)
        putWebMountPostcondition()
        put("selector", buildJsonObject {
            put("type", "string")
            put("description", "Optional CSS selector to scroll for direct user actions; when target is supplied, omit selector or provide the same value. Agent calls should use target.")
        })
        put("target", buildJsonObject {
            put("type", "string")
            put("description", "Preferred target ref from wm_extract/wm_find; if selector is also supplied, target takes precedence when both values agree and conflicting values are rejected.")
        })
        put("to", buildJsonObject {
            put("type", "string")
            put("description", "Named position such as top, bottom, or visible")
        })
        put("by_y", buildJsonObject {
            put("type", "number")
            put("description", "Vertical pixel delta")
        })
    },
    required = if (requireSessionSnapshot) listOf("session_id", "snapshot_id") else null
)

private fun webMountFindParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
        putWebMountSnapshotId()
        put("selector", buildJsonObject {
            put("type", "string")
            put("minLength", 1)
            put("description", "Non-empty CSS selector to find. Provide exactly one of selector or text.")
        })
        put("text", buildJsonObject {
            put("type", "string")
            put("minLength", 1)
            put("description", "Non-empty text to find on the page. Provide exactly one of selector or text.")
        })
        put("max_results", buildJsonObject {
            put("type", "integer")
            put("description", "Maximum matches to return")
        })
    }
)

private fun webMountWaitParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        putWebMountSessionId()
        put("condition", buildJsonObject {
            put("type", "string")
            put("description", "Observable condition; defaults to dom_stable. document_changed and url_changed wait for a new page identity; ready_state and dom_stable report readiness only and cannot verify an action goal.")
            put("enum", buildJsonArray {
                add("dom_stable")
                add("selector")
                add("text")
                add("url_contains")
                add("ready_state")
                add("document_changed")
                add("url_changed")
                add("delay")
            })
        })
        put("selector", buildJsonObject {
            put("type", "string")
            put("description", "selector or target ref to wait for when condition=selector")
        })
        put("text", buildJsonObject {
            put("type", "string")
            put("description", "visible page text to wait for when condition=text")
        })
        put("url_contains", buildJsonObject {
            put("type", "string")
            put("description", "URL fragment to wait for without returning query values")
        })
        put("before_document_id", buildJsonObject {
            put("type", "string")
            put("description", "Optional document identity captured before the action; used with condition=document_changed")
        })
        put("before_url", buildJsonObject {
            put("type", "string")
            put("description", "Optional redacted URL captured before the action; used with condition=url_changed. Prefer the URL revision from wm_state or wm_observe when same-document query or hash changes matter.")
        })
        put("before_url_revision", buildJsonObject {
            put("type", "integer")
            put("description", "Optional URL revision captured from wm_state or wm_observe before the action; with before_document_id, detects same-document URL, query, or hash changes without exposing the raw URL")
        })
        put("before_dom_revision", buildJsonObject {
            put("type", "integer")
            put("description", "Optional DOM revision captured from wm_state or wm_observe before the action; used as page-change evidence with require_page_change")
        })
        put("require_page_change", buildJsonObject {
            put("type", "boolean")
            put("description", "Require a new document, URL revision, or DOM revision in addition to the condition. A revision change is observation evidence and does not by itself verify the business goal.")
        })
        put("ready_state", buildJsonObject {
            put("type", "string")
            put("description", "document ready state to wait for; interactive or complete")
            put("enum", buildJsonArray {
                add("interactive")
                add("complete")
            })
        })
        put("stable_ms", buildJsonObject {
            put("type", "integer")
            put("description", "required unchanged DOM interval for dom_stable, clamped by iOS")
        })
        put("timeout_ms", buildJsonObject {
            put("type", "integer")
            put("description", "bounded deadline in milliseconds, clamped to 100...30000 by iOS")
        })
    }
)

private fun subAgentReportParameters(): InputSchema = InputSchema.Obj(
    properties = buildJsonObject {
        put("summary", buildJsonObject {
            put("type", "string")
            put("description", "Concise final summary")
        })
        put("findings", buildJsonObject {
            put("type", "array")
            put("description", "Key findings")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("evidence", buildJsonObject {
            put("type", "array")
            put("description", "Evidence or source references")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("risks", buildJsonObject {
            put("type", "array")
            put("description", "Risks, uncertainty, or limitations")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("recommended_next_steps", buildJsonObject {
            put("type", "array")
            put("description", "Recommended next steps")
            put("items", buildJsonObject { put("type", "string") })
        })
        put("confidence", buildJsonObject {
            put("type", "number")
            put("description", "Confidence from 0 to 1")
        })
    }
)

@Serializable
sealed class InputSchema {
    @Serializable
    @SerialName("object")
    data class Obj(
        val properties: JsonObject,
        val required: List<String>? = null,
        val description: String? = null,
        val additionalProperties: Boolean? = null,
        @SerialName("enum") val enumValues: JsonArray? = null,
    ) : InputSchema()
}
