# PLAT-1 actual simulator UI red

Device: B3C3F24B-7D39-4695-86BB-588EEC6469A4, Amber Audit 20261018, iOS 26.5. Only task-owned simulator data was changed; original F3D device and real devices untouched. Existing installed app, no build, test framework or diagnostic launch argument.

1. Add two valid owned conversation JSON documents and derived index entries, using the current app schema. IDs and container in manifest.json; original index preserved as index.before.json.
2. Launch ordinary app, enter Home search, then global Search, type TARGET using physical keystrokes.
3. Control: activate title hit AUDIT SEARCH TARGET. UI shows AUDIT SEARCH TARGET and TARGET BODY: expected selected conversation. See control-before-ax.json and control-after-ax.json.
4. Navigate back to same Search, select the ORIGINAL message result, verify AUDIT SEARCH ORIGINAL and ORIGINAL BODY as current. See original-current-ax.json. Navigate back to same Search; TARGET result remains displayed.
5. Replace only the owned TARGET JSON with invalid bytes while its search hit remains visible; activate its title hit.
6. Actual erroneous result: navigation opens chat titled AUDIT SEARCH ORIGINAL with ORIGINAL BODY: must not appear when selecting target. See red-before.png, red-after.png and red-after-ax.json. Expected behavior is stay in Search with an actionable failure.

After evidence, restored the owned target to its valid bytes. The two new owned conversations remain available for the green reproduction; no original data was deleted.

Tool boundary: XcodeBuildMCP snapshot_ui and Synara describe_ui correctly exposed the ordinary app. Inprocess unit-test SwiftUI AX was empty despite a valid rendered screenshot and cannot be used as navigation evidence. Xcode tap and Synara label-based taps changed no screen; direct Synara tap using current screenshot device coordinates actually invoked controls. No conclusions about product touch input were drawn from those failed tool actions.

## PLAT-1 final UI green

Root final integration app was installed and launched on the same dedicated simulator. Valid target opens TARGET title/body; after ORIGINAL is current and only the displayed target document is corrupted, activating its hit stays in Search and displays 无法打开会话 / 该会话暂时无法打开。 Dismissing the error preserves query TARGET and the hit list. Restoring the valid target bytes and activating the same existing hit then opens the correct TARGET title/body. After another failed target selection and cancelling Search, Home still highlights ORIGINAL as current. See green-verification.md, green-control/error/retry/current-retained PNGs, and green-*-ax.json. The target bytes were restored and only the task-started app was stopped before handing the simulator back.

## PLAT-2 Home keyboard-submit red

1. From ordinary Home, tap Search to expand its inline field. Type ASCII TARGET with keystrokes, without injecting Search results or changing any source.
2. The inline field shows TARGET and Home filtering shows only AUDIT SEARCH TARGET; ORIGINAL and the unrelated empty conversation disappear. This confirms the SwiftUI query backing the filter holds TARGET.
3. Commit the keyboard candidate if required (first Search key may commit marked text without navigating). The separate committed-before AX/screenshot shows punctuation suggestions, TARGET still in the inline field, and only the target row.
4. Tap the actual on-screen keyboard Search key at device point (350, 779). This actual touch navigates into Global Search with an empty query, 最近会话 heading, and all three recent rows, losing the submitted filter.
5. Evidence: home-submit-committed-before-ax.json/png and home-submit-after-ax.json/png. The Home field/filter and entered destination distinguish a real submit from tool-only focus changes. Root independently accepted PLAT-2 and owns its minimal source repair; this agent made no Home code edits.

## PLAT-2 final v2 UI green

The latest Root-built v2 app was installed on the same dedicated simulator. Home TARGET filtering followed by the real keyboard Search key now opens Global Search with TARGET preserved and the expected hits. Inline Cancel and tapping outside both collapse search and restore all three rows; each subsequent expansion exposes an empty native field, and typing TARGET once produces exactly TARGET with only the matching Home row. See home-v2-verification.md, home-v2-submit.png, home-v2-retyped.png, and the home-v2-*-ax.json sequence. An ordinary list swipe left the keyboard focused, so no separate pure-scroll dismissal path was observed. No empty-library data manipulation was performed. The initial Home repair's residual-text regression remains explicitly recorded in home-validation.md; v2 evidence is separate. The app was stopped before returning the simulator for Root's full main tests.
