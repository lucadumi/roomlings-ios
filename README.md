# Roomlings for iOS

SwiftUI for iPhone and iPad, using the [web app's](https://github.com/lucadumi/roomlings) shared Three.js graphics.

## Installation

Requires **Xcode**, **iOS 18+**, **Node.js 22.18+** and the web checkout at `../roomlings`.

Use the web revision pinned in [CI](.github/workflows/ci.yml), or a compatible newer checkout.

```sh
npm --prefix ../roomlings ci
open Roomlings.xcodeproj
```

Run the **Roomlings** scheme on a simulator. Physical devices need your signing team.
Keep `npm --prefix ../roomlings run preview:local` running for local sign-in.
Local overrides: `NODE_BINARY`, `ROOMLINGS_WEB_ROOT`, `ROOMLINGS_API_SCHEME`, `ROOMLINGS_API_HOST` in `Configuration/Local.xcconfig`.

## Usage

- Sign in or recover access, create/join a household, and open its saved kitchen.
- Open an object's **+** marker or **Chores** to view, add, complete and undo shared tasks, with schedules and rotations saved on the server.
- Open **Shopping** to add, edit, claim and pick up items without creating debt, then record a paid receipt that splits it in the shared ledger.
- Object taps focus the camera; the iPhone's portrait room view is 35% closer.
- Shared web fonts, colours, graphics and logo loaders; sessions stay in the native Keychain.
- [Native API and Keychain guide](Packages/RoomlingsCore/README.md).

## Contributing

```sh
swift test --package-path Packages/RoomlingsCore
node Scripts/build-room.mjs
node --test Tests/RoomRenderer/room-renderer.test.mjs
node Scripts/test-accounts.mjs
```

Use **Product > Test** for room controls. Follow the [contributor rules](AGENTS.md); changes go through PRs.
Use `node Scripts/test-accounts.mjs --chores-only` for the isolated native chores flows.
Shopping flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testShoppingEditsClaimsAndPicksWithoutCreatingDebt`.
Receipt flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testReceiptsRecordTheSharedSplitAndClearTheBasket`.
Use `--ui-test TestClass/testMethod` to select individual UI flows.

[CI](.github/workflows/ci.yml) covers Swift, the shared renderer, and iPhone/iPad flows.
