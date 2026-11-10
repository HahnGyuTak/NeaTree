# NeaTree project instructions

- Read `docs/PLAN.md` and `DESIGN_REQUIREMENTS.md` before changing behavior or visuals.
- Product name: NeaTree (Neat + Tree). Keep the name consistent in the app and distribution artifacts.
- Menu bar proposal mockup v1 was approved on 2026-11-11 (“이 시안대로 구현”).
- This is a native macOS SwiftUI/AppKit app distributed through GitHub Releases, not the App Store.
- Preserve Finder's sidebar/list/preview structure and the user-specified Liquid Glass components. Do not invent unrelated accents or decoration.
- The user has asked to begin app development following the shown preview and recorded design rules. New visual directions still follow the image-review requirement in the design document.
- Keep filesystem decisions in OrganizerCore. UI actions must validate the source and destination through the service; never rename files directly in a view.
- Do not scan personal directories, make paid API requests, or modify user files just to test the app. Use isolated fixtures and demo state.
- Never commit keys, local state, personal absolute paths, signing credentials, or compiled apps. Ship versioned binary archives through Releases.
- Only mark a distribution build signed/notarized after the corresponding checks succeed. Document development builds accurately.
- Run the checks relevant to each change. Visual behavior should be inspected in the native preview; filesystem and state transitions require meaningful tests.
