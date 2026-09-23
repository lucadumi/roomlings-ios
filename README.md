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
Debug overrides: `NODE_BINARY`, `ROOMLINGS_WEB_ROOT`, `ROOMLINGS_API_SCHEME`, `ROOMLINGS_API_HOST` in `Configuration/Local.xcconfig`.
Release uses its own `Configuration/Release.local.xcconfig`. See the [TestFlight guide](docs/testflight.md) for archive safeguards and outstanding prerequisites.

## Usage

- Sign in or recover access, create/join a household, and open its saved kitchen.
- Owners can share seven-day invitations and revoke pending links in **Account**. Paste local links into **Join a household**; app-opening links await a public domain. [Invitation setup](Packages/RoomlingsCore/README.md#invitations).
- Open an object's **+** marker or **Chores** to view, add, complete and undo shared tasks, with schedules and rotations saved on the server.
- Open **Shopping** to add, edit, claim and pick up items without creating debt, then record a paid receipt that splits it in the shared ledger.
- Open **Money** for receipts, what each roommate owes or is owed, and repayments. Roomlings tracks money; it never moves it.
- The branded header opens **Account** from the household name or your avatar.
- **Account > Household members** shows the current roster and lets the owner confirm a handoff to another active account-linked roommate, without changing shared balances.
- **Account > Notifications** saves chore and money preferences. Enable push explicitly on each account/device; delivery requires the server and Apple signing setup in the [native guide](Packages/RoomlingsCore/README.md).
- **Account > Account lifecycle** offers native account deletion with exact email confirmation, re-verification and pending-deletion recovery. [What deletion keeps](Packages/RoomlingsCore/README.md#account-deletion).
- The larger room view adapts to the window in both orientations. Zoom includes object focus; **Reset room view** returns to 100%.
- Shared web fonts, colours, error banners, graphics and static logo loaders; the approved mark also supplies the app icon and centred launch screen. Sessions stay in the native Keychain.
- Minimal [retention events](Packages/RoomlingsCore/README.md#retention-analytics) go only to Roomlings, without message content or a third-party SDK.
- The app bundles privacy declarations; see the [native data inventory](docs/privacy.md) before distribution.
- [Native API and Keychain guide](Packages/RoomlingsCore/README.md).

## Contributing

```sh
swift test --package-path Packages/RoomlingsCore
node --test Tests/Release/release.test.mjs
node Scripts/build-room.mjs
node --test Tests/RoomRenderer/room-renderer.test.mjs
node Scripts/test-accounts.mjs
```

Use **Product > Test** for room controls. Follow the [contributor rules](AGENTS.md); changes go through PRs.
Use `node Scripts/test-accounts.mjs --chores-only` for the isolated native chores flows.
Shopping flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testShoppingEditsClaimsAndPicksWithoutCreatingDebt`.
Receipt flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testBalancesMatchTheServerAndRepaymentsCanBeUndone`.
Use `--ui-test TestClass/testMethod` to select individual UI flows.
Notification flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testNotificationMutesPersistAfterRelaunchWithoutPermissionOrDeliveryConfiguration`.
Analytics flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testAnalyticsCountsForegroundVisitsButNotSheetRefreshes --ui-test AccountUITests/testAnalyticsLostResponseDoesNotRetryOrHideHouseholdTools`.
Deletion flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testAccountDeletionRequiresExactConfirmationAndKeepsTheSharedLedger --ui-test AccountUITests/testAccountDeletionPendingSurvivesRelaunchAndOffersANativeRetry`.
Ownership flows: `node Scripts/test-accounts.mjs --ui-test AccountUITests/testOwnershipTransferConfirmsTheNamedMemberAndPreservesTheLedger --ui-test AccountUITests/testAnUnconfirmedOwnershipTransferMustBeRefreshedWithoutRepeatingIt`.

[CI](.github/workflows/ci.yml) covers Swift, the shared renderer, and iPhone/iPad flows.
