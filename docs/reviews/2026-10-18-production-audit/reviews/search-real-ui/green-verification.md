# PLAT-1 actual UI green

Installed Root final integration app: /Users/arquiel/Library/Developer/Xcode/DerivedData/AmberAgent-bjiohjyzqxbgaocvnuyszcwtjbyd/Build/Products/Debug-iphonesimulator/iosApp.app. Device B3C3F24B-7D39-4695-86BB-588EEC6469A4, iOS 26.5. No build was run by this agent.

1. Normal result control passed: Search query TARGET, tap target title hit, chat title AUDIT SEARCH TARGET and TARGET BODY visible (green-control-ax.json, green-control.png).
2. Set current to ORIGINAL using its real Search message hit; chat title/body confirmed (green-original-before-ax.json). Return to same Search results.
3. Corrupt only task-owned TARGET JSON in the currently installed app container (0259C6F3-BD1B-40B6-9FA9-FD16C4F7942B). Tap its already-visible title hit: stay on Search, visible alert 无法打开会话 / 该会话暂时无法打开。 (green-error-ax.json, green-error.png). No wrong-chat navigation.
4. Dismiss alert: same TARGET query and original title/message hit list remain (green-retained-results-ax.json).
5. Restore owned valid target bytes while keeping that Search instance and published hits. Tap the same title hit without re-searching: correct TARGET title/body opens (green-retry-ax.json, green-retry.png).
6. Required current-retention check: repeat unavailable target while ORIGINAL is current, dismiss and cancel Search. Home still visually marks ORIGINAL with its current-session accent/avatar; TARGET remains ordinary (green-current-retained.png, inspected directly). Restore target valid bytes.

The unrelated Home keyboard-submit loss was separately recorded: home-submit-committed-before-ax.json/png shows committed TARGET and only matching Home row; direct keyboard Search tap produces home-submit-after-ax.json/png showing global empty query + Recent conversations. Root owns its new PLAT-2 repair. No Home production code changed by this agent.

After all evidence, stopped only the task-started app and handed the simulator back to Root. Owned target bytes are valid. No original device or physical device touched, no provider request sent. Rapid superseding/dismissal timing is source-reviewed; no artificial UI timing race was claimed.
