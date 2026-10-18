# Home PLAT-2 v2 actual UI verification

Device: B3C3F24B-7D39-4695-86BB-588EEC6469A4 (task-owned Amber Audit simulator, iOS 26.5). Installed the latest Root-built iosApp.app after the Home v2 build succeeded. No local build, unit-test run, production changes, or data mutations were performed by this agent during this verification.

All required primary flows passed through ordinary app UI and real keyboard/control taps:

1. Expand Home Search and type TARGET. The native field reports exactly TARGET and the Home list contains only AUDIT SEARCH TARGET (home-v2-before-ax.json).
2. With the current keyboard, the first Search key commits marked text; the next actual Search tap navigates. Global Search keeps field value TARGET and shows the target title hit and message hits (home-v2-submit-ax.json, home-v2-submit.png). This verifies the submitted Home query reaches the real Search consumer.
3. Return Home, expand and type TARGET, then tap inline Cancel. Home collapses Search and restores all three conversation rows (home-v2-cancel-ax.json).
4. Expand again. The native field has placeholder 搜索会话 and no value, and all three rows remain visible (home-v2-cancel-reopen-ax.json). Type TARGET once: fieldValue and native field are exactly TARGET, with only the target Home row (home-v2-cancel-retyped-ax.json).
5. Tap the 会话 heading outside the field. Home collapses and restores all three rows (home-v2-outside-ax.json). Expand again: placeholder/no value and all three rows (home-v2-outside-reopen-ax.json). Type TARGET once: exactly TARGET and only the matching row (home-v2-outside-retyped-ax.json, home-v2-retyped.png). No residual text concatenation was observed.

One ordinary list swipe from (201,460) to (201,300) did not dismiss the keyboard or change the screen; the field remained focused with TARGET (home-v2-scroll-ax.json, home-v2-scroll.png). Therefore a separate pure-scroll keyboard-dismissal path was not observed or accepted as covered. No artificial controls or new framework were introduced to force that path. The optional empty-library appearance was not exercised, and no existing conversation data was moved.

The first Home revision's actual residual-text regression remains documented in home-validation.md and its original evidence files. In particular, home-green-reopen-empty.png is retained as a FAILURE screenshot despite its planned filename; v2 evidence uses the separate home-v2 prefix.

The app was successfully stopped with stop_app_sim and the simulator was handed back to Root for the main full test run. No simulator operations will run concurrently from this agent. This is simulator behavior evidence, not physical-device or real-provider acceptance.
