# Roomlings for iOS

Initial native setup for iPhone and iPad, targeting iOS 18 and later. SwiftUI hosts the web app's existing Three.js kitchen inside a local WKWebView. The renderer is bundled with the app and opens without a web server or an internet connection.

This is the initial foundation, not a finished account or household app. The kitchen's camera, fridge, kettle and lighting controls work locally. Account screens, mobile navigation, the other rooms and ledger workflows are deliberately not presented as unfinished controls. Their UI needs the owner's approval.

## Open and run

Requires full Xcode, an installed iOS simulator, Node.js compatible with the sibling Roomlings web repository, and that repository's locked npm dependencies.

1. Keep the web checkout next to this directory as `../roomlings`, or set `ROOMLINGS_WEB_ROOT` in `Configuration/Local.xcconfig`.
2. Use a current web checkout that includes the `KitchenPreview` export in `src/KitchenWorld.tsx`. This opt-in adapter is part of the web repository's `main` branch.
3. Install web dependencies in that checkout with `npm ci` if they are missing. Do not copy its `node_modules` or models into this repository.
4. Open `Roomlings.xcodeproj`, select the shared **Roomlings** scheme and choose an iPhone or iPad simulator.
5. Run the app. The Xcode build phase type-checks and bundles the shared scene automatically.

`NODE_BINARY` defaults to `/opt/homebrew/bin/node`. Set it to the output of `command -v node` in `Configuration/Local.xcconfig` if your installation differs. That ignored file can also hold your local development team setting. No signing team or private credentials are committed.

```xcconfig
ROOMLINGS_WEB_ROOT = $(PROJECT_DIR)/../roomlings
NODE_BINARY = /usr/local/bin/node
```

For a physical device, select your own signing team in Xcode. No Android, Mac Catalyst or visionOS app target is included.

## Shared graphics

`Scripts/build-room.mjs` imports the real web `KitchenPreview`, React components, Three.js dependencies, models, textures, materials, lights, shadows, fonts and camera logic. It does not contain a second scene implementation. `RoomRenderer/viewport.css` only fits the existing viewer and controls into the native viewport.

The web-side preview adapter is opt-in. It leaves the normal household viewer unchanged and exposes only working local scene actions. It creates no household, identity or financial history.

The generated `Build/RoomRenderer` directory is ignored. Xcode copies it into the app bundle. Its `source.json` records the web commit, whether there were local source edits and the dependency-lock hash. Rebuild the app after web graphics changes. Installed app versions do not automatically follow future web deployments; matching visuals requires using the matching renderer source revision.

Build the bundle separately when working on the integration:

```sh
node Scripts/build-room.mjs
```

## Native boundary

The WKWebView uses nonpersistent website storage, permits navigation only to its bundled entry file, and restricts file access to the renderer directory. The page's Content Security Policy disallows network connections and external frames. It cannot receive account tokens or call the account API through the bridge.

Pinch zoom belongs to the room camera, not the web document. The host activates valid single-finger control taps once and suppresses WebKit's delayed compatibility click, which can otherwise target the previous control. Dragging and multi-touch camera gestures are left to the shared renderer; mouse and keyboard activation keep their normal behavior.

Bridge protocol version 1 accepts only a native state message containing `paused` and a validated `roomStyle`. The renderer reports `loading`, `ready` or `unavailable` after actual initialization. The native app sends lifecycle changes through structured `callAsyncJavaScript` arguments, not interpolated script strings. Unknown message shapes fail explicitly, and a terminated renderer offers a real reload action.

`Packages/RoomlingsCore` supplies the native API and Keychain foundation for later screens. It uses the server's `X-Roomlings-Client: ios` bearer-session contract, now included in the web repository's `main` branch. The initial preview does not sign in, call the API or alter an existing household. Live native account access requires running a server that includes this feature; merging source code does not itself restart or deploy a server.

Production API origins must use HTTPS. HTTP is permitted by the API configuration only for loopback development. Keychain credentials must remain device-only and must never be copied into the web renderer, URLs, logs, `UserDefaults` or this repository.

## Development commands

```sh
swift test --package-path Packages/RoomlingsCore
node --test Tests/RoomRenderer/room-renderer.test.mjs

xcodebuild -project Roomlings.xcodeproj -scheme Roomlings \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath Build/DerivedData test
```

Choose an installed simulator name on your machine. The shared Xcode scheme includes native bridge tests and a room interaction scenario that can run on both iPhone and iPad. `Build`, `DerivedData`, test results and Xcode user state are ignored.

The mobile repository is [lucadumi/roomlings-ios](https://github.com/lucadumi/roomlings-ios). Keep changes local until the owner explicitly approves publication.
