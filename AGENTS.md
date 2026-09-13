# Working on Roomlings for iOS

Roomlings is an iPhone and iPad app, with iOS 18 as its minimum deployment target.

- Use Swift 6 and SwiftUI for the native app.
- Bundle the web app's existing Three.js room renderer in WKWebView. Do not recreate the graphics in SceneKit or RealityKit, or fork copies of the models, lighting, materials or animations.
- Keep the renderer source in the sibling web project. The local build must record the source revision and fail clearly if the required web source or dependencies are missing.
- Keep authentication, API requests and Keychain storage native. Do not expose session tokens to JavaScript, browser storage, logs or URLs.
- The shared server ledger remains authoritative. Keep money in integer cents and preserve optimistic version checks.
- Consult the owner before new UI, UX, branding or navigation decisions. The initial app is a room-rendering foundation, not a collection of placeholder screens.
- Every visible control must work. Do not show unfinished household actions.
- Handle failed requests and failed credential storage explicitly. Never present a failed save as successful.
- Preserve the existing web checkout, data, browser sessions and review server.
- Work on a local `feat/...` branch. Do not push, create a remote repository or open a pull request without explicit approval.
- Commit messages are short imperative sentences without bodies, trailers or attribution watermarks. Do not use em dashes.
- Keep generated bundles, build output, signing credentials and test artifacts out of commits.
