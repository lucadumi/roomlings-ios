# Roomlings for iOS

SwiftUI for iPhone and iPad, using the [web app's](https://github.com/lucadumi/roomlings) shared Three.js graphics.

## Installation

Requires **Xcode**, **iOS 18+**, **Node.js 22.18+** and the web checkout at `../roomlings`.

```sh
npm --prefix ../roomlings ci
open Roomlings.xcodeproj
```

Run the **Roomlings** scheme on a simulator. Physical devices need your signing team.
Override `ROOMLINGS_WEB_ROOT` or `NODE_BINARY` in ignored `Configuration/Local.xcconfig`.

## Usage

- Offline kitchen preview with camera, fridge, kettle and lighting controls.
- [Native API and Keychain guide](Packages/RoomlingsCore/README.md).

## Contributing

```sh
swift test --package-path Packages/RoomlingsCore
node Scripts/build-room.mjs
node --test Tests/RoomRenderer/room-renderer.test.mjs
```

Use **Product > Test** for device flows. Follow the [contributor rules](AGENTS.md); changes go through PRs.
