# Phase 4 — playable Flutter interface

Implementation/verification: 2026-09-10; final review reconciliation: 2026-09-11. Claude's original progress record remains at [phase-4-progress-claude.md](phase-4-progress-claude.md). This document records the subsequent work and supersedes its pending-work statements, without changing its authorship.

The board, owner hand, public roster, build/trade/development controls, setup/robber/discard prompts, history, pending/reconnect/paused/result panels and rematch confirmation are implemented. Phase 5 connects the same screen to authenticated rooms and a real host-only rematch command.

Changes after reviewing Claude's work:

- Replaced the no-op preview with a separate loopback-only Socket.IO harness running the real pure engine, nine conserved scenarios and automated opponents. A reconnect token preserves the practice table. The production entry point never imports the preview. Practice rematch resets practice; it does not create a private room.
- Added an engine-generated oracle fixture for Dart legal-target previews. All nine scenes agree with moves accepted by the engine.
- Made non-active players' trade controls reachable, enforced one give/receive resource for bank trades, guarded stale modal choices against their originating snapshot, and prevented zero-obligation discard prompts.
- Added target selection alternatives, scrollable card/resource dialogs, a landscape board/panels split, and bounded zoom buttons. Replaced emoji dice with the bundled Material icon after screenshot inspection.
- Opened and scrolled six modal surfaces at two viewport sizes (320×640, 812×375) and two text scales (1×, 2×): 24 cases. These tests cover trade, discard, Monopoly, Year of Plenty, cards and rematch dialogs, beyond the original screen-only matrix.

## Verified evidence

| Check | Result |
| --- | --- |
| Existing plus Phase 4 Flutter suite, before Phase 5 client tests | 198 passing |
| Practice server/fixture tests | 12 passing; included in `npm test` |
| Android emulator, API 35 | Three interactive practice tests passed: both setup rounds; pinch/pan/fit; road/city/card purchase; a real winning purchase |
| iPhone 17 Pro simulator, iOS 26.2 | The same three interactive practice tests passed |
| Portrait/landscape and enlarged text | Automated screen and modal matrices pass without overflow |
| Web | Production four-browser interactive verification is recorded in the Phase 5 evidence |

Native tests use actual pointer/button actions against the practice engine, not mocked acknowledgements. Early iOS attempts exposed brittle test locators/scroll timing: the corrected test taps the visible dropdown text, scrolls results into view, and supplies intermediate pinch frames. The final iOS run passed all three tests. These native practice checks do **not** establish authenticated native multiplayer; Phase 5's four-browser and Socket.IO tests establish that separate boundary.

Run practice locally:

```sh
# Repository root
npm run preview:engine
# Separate terminal
cd apps/mobile
flutter run -t lib/preview.dart -d chrome --web-port=8081
# Device integration check; use an actual listed simulator/emulator ID
flutter test --no-pub integration_test/game_flow_test.dart -d DEVICE_ID --reporter expanded
```

On Android add `--dart-define=PRACTICE_URL=http://10.0.2.2:3001`. Run `npm run fixtures:ui` to regenerate the advisory-target fixtures when deliberately changing engine fixtures.

Physical phones, Safari, physical-device signing and real mobile-network transitions remain unverified. No external assets or hosted infrastructure were deployed. Phase 6 supplies actual timer/disconnect pause behavior; the Phase 4 panels alone are not evidence of that behavior.
