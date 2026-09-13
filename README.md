# Roomlings for iOS

SwiftUI for iPhone and iPad, using the [web app's](https://github.com/lucadumi/roomlings) shared Three.js graphics.

## Installation

Requires **Xcode**, **iOS 18+**, **Node.js 22.18+** and the web checkout at `../roomlings`.

```sh
npm --prefix ../roomlings ci
open Roomlings.xcodeproj
```

Run the **Roomlings** scheme on a simulator. Physical devices need your signing team.
Keep `npm --prefix ../roomlings run preview:local` running for local sign-in.
Local overrides: `NODE_BINARY`, `ROOMLINGS_WEB_ROOT`, `ROOMLINGS_API_SCHEME`, `ROOMLINGS_API_HOST` in `Configuration/Local.xcconfig`.

## Usage

- Sign in or recover access, create/join a household, and open its saved kitchen.
- Shared web fonts, colours and graphics; sessions stay in the native Keychain.
- [Native API and Keychain guide](Packages/RoomlingsCore/README.md).

## Contributing

```sh
swift test --package-path Packages/RoomlingsCore
node Scripts/build-room.mjs
node --test Tests/RoomRenderer/room-renderer.test.mjs
node Scripts/test-accounts.mjs
```

Use **Product > Test** for room controls. Follow the [contributor rules](AGENTS.md); changes go through PRs.
