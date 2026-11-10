# Shared tile chrome

These are verification recipes, not executed results. Follow [verify-easl](../SKILL.md) for guest ownership, isolated homes, exact-head launches, native capture, and cleanup. No test, guest, or performance pass is recorded here.

## Sub-features

- `chrome-types` covers all tile types and custom-title glyphs.
- `chrome-state` covers keyboard ownership, terminal-only lifecycle, and classifier reasons.
- `chrome-author` covers creation snapshots, legacy resolution, and full-name access.
- `chrome-fold` covers two tracks at ChromeText 100% and 115%, and folding at 130% and 150%.
- `chrome-geometry` covers unchanged persisted frames, fit, routing, mentions, and API renders.
- `chrome-controls` covers native controls and title-bar interactions at every text level.

## How to get to it (user POV)

Open a board with terminal, browser, note, code, HTML, image, video, diagram, question, and changes tiles. Use View > Increase Chrome Text Size, Decrease Chrome Text Size, and Reset Chrome Text Size. Board zoom and ChromeText are separate settings.

## Driving it with dev.sh

Preconditions: isolated guest app homes, disposable board roots, and a scratch easld for remote cases. Record the app and host heads separately. Use native input through `scripts/dev.sh input` and API actions through `scripts/dev.sh cli`, with the correct `EASL_DEV_HOME` each time.

1. Create every tile type above, including custom and long titles. Capture fresh native pixels in light and dark at 100% and 50% board zoom. Inspect every glyph, title, author, and state. Save a contact sheet with the source PNGs and capture receipts; `view.snapshot` is not native proof.
2. At both board zooms and in both appearances, capture ChromeText 100% and 115% two-track bars, then 130% and 150% folded bars. Require type, title, states, and needs-you pill in that order when folded. Hover for the author and inspect its complete accessibility text. Inspect narrow bars, long names, and simultaneous typing plus working for clipping or text-ink overlap. Transparent label rectangles are not text ink.
3. Compare 100% and 115% against their pre-fold reference captures with identical board content, appearance, viewport, and keyboard owner. Require unchanged layout, metrics, fonts, and text at those levels. Stop rather than adjust either level to accommodate folding. Verify reset restores the original two-track layout without changing tile frames.
4. Exercise none, typing, working, typing plus working, idle, blocked, done, and error. Typing must follow the actual keyboard holder, not selection alone. Only terminals may show lifecycle or command state; tiles created by a working terminal remain neutral unless they independently hold keys or need the user. Exercise each classifier reason: blocked, open question, marked attention, and unseen result. Include needs-you on a non-terminal. Require static reason text and a screen-sized pill readable at 50% board zoom.
5. On both Swift and Go hosts, create user-authored and agent-authored objects. Require `you` for user provenance and the stored creation name for agents. Rename then delete the creator, save/reopen, and replicate to another viewer. Require unchanged `authorName` and visible attribution. Include a long stored name with tail truncation and full tooltip/accessibility text. Use an existing legacy object without `authorName`; require live legacy resolution without writing a snapshot. Swift may capture an available foreground program; Go falls back through name, title, agent kind, and `Terminal` without a program source.
6. Exercise title dragging, close, content zoom, browser navigation and drawing-machine controls, terminal controls, and question actions where present, at every ChromeText level. Require controls to remain reachable without covering title or state ink. Preserve existing selection and keyboard-routing rules.
7. Read frames before and after reopen and ChromeText changes. Require persisted frames unchanged and bodies 8 pt shorter than the old 26 pt geometry. Compare `object.measure`, `size: "fit"`, newly created counted questions, content routing, and mentions on both hosts using 34 pt. Keep the historical format-1-to-2 migration at +26 pt. Capture `view.render` locally and through easld delegation while the viewer uses 150% ChromeText; require scale-1 two-track chrome, not the viewer's folded layout.
8. In isolated old/new instances, record 0.3.9 viewer with new easld and new viewer with 0.3.9 easld. The former retains old marks and ignores snapshots; the latter uses legacy resolution for missing snapshots without backfill. Record the 8 pt body-geometry mismatch at 1x and its fit, routing, and mention effects. This is not a compatibility pass. Deploy every drawing and viewing Mac before easld; add no compatibility workaround.

## Gotchas

- `Sources/CanvasCore/TileChrome.swift` owns state applicability, classifier text, type symbols, and role names. `Sources/CanvasApp/TileChrome.swift` maps roles to native semantic colors and fonts without configuration.
- `AuthorMark.swift`, `Board.swift`, and `easld/internal/board/board.go` distinguish creation snapshots from legacy live lookup. Never backfill legacy names or hand-edit conformance fixtures.
- ChromeText scales text, not the 34 pt bar. Board zoom does not select the folded layout.
- Record conformance fixtures only from the Mac development app in the guest, following `docs/testing.md`; scratch-easld recordings are not authoritative.
- Performance qualification is separate. Follow [the performance procedure](../performance.md) and the lane's paired workload; do not infer idle CPU, wakeups, or main-thread stretch results from screenshots.
