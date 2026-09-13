# Working on Roomlings for iOS

Roomlings is an iPhone and iPad app, with iOS 18 as its minimum deployment target.

- Use Swift 6 and SwiftUI for the native app.
- Bundle the web app's existing Three.js room renderer in WKWebView. Do not recreate the graphics in SceneKit or RealityKit, or fork copies of the models, lighting, materials or animations.
- Keep the renderer source in the sibling web project. The local build must record the source revision and fail clearly if the required web source or dependencies are missing.
- Keep authentication, API requests and Keychain storage native. Do not expose session tokens to JavaScript, browser storage, logs or URLs.
- Match the web UI as well as its graphics: generate colours and control radius from the shared CSS, and use the licensed DM Sans and Baloo 2 fonts.
- Keep the generated `WebThemeValues.swift` reference in Xcode and its build-phase output declaration; the native theme depends on it.
- Account entry uses a native sheet over the room, bottom-aligned on iPhone and centered on iPad.
- Fill the screen with the shared room background, including behind system bars. Keep native and room controls within measured safe-area insets.
- The shared server ledger remains authoritative. Keep money in integer cents and preserve optimistic version checks.
- Consult the owner before new UI, UX, branding or navigation decisions. The initial app is a room-rendering foundation, not a collection of placeholder screens.
- Every visible control must work. Do not show unfinished household actions.
- Handle failed requests and failed credential storage explicitly. Never present a failed save as successful.
- Preserve the existing web checkout, data, browser sessions and review server.
- Work on a local `feat/...` branch. Do not push, create a remote repository or open a pull request without explicit approval.
- Commit messages are short imperative sentences without bodies, trailers or attribution watermarks. Do not use em dashes.
- Keep generated bundles, build output, signing credentials and test artifacts out of commits.
- Base the web and iOS root READMEs on [Make a README](https://www.makeareadme.com/). Keep them very short, without big paragraphs, and link to detailed guides.
- Build on the existing README templates as features land; do not replace them with long implementation summaries.
- After the initial bootstrap, use feature branches and pull requests rather than direct pushes to `main`.
- CI uses a pinned public web revision and its locked dependencies. Keep the Playwright image aligned with that lockfile; simulator flows need no real account or signing secrets.
