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
See [development setup](docs/development.md) for configuration and tests.

## Usage

Sign in, create or join a household, then use **Chores**, **Shopping** and **Money** from its room.
Tap the household name or your avatar for **Account**.

- [App guide](docs/usage.md)
- [Invitations and public links](docs/invitations.md)
- [TestFlight setup](docs/testflight.md) and [privacy](docs/privacy.md)

## Contributing

Follow the [contributor rules](AGENTS.md); work on feature branches and submit changes through PRs.
See [development and testing](docs/development.md) and the [native API guide](Packages/RoomlingsCore/README.md).
