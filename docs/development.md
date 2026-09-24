# Development and testing

## Local setup

Follow the root [installation steps](../README.md#installation) and [contributor rules](../AGENTS.md).
Keep the sibling web checkout on the revision pinned in [CI](../.github/workflows/ci.yml), or a compatible newer revision, with its locked dependencies installed.
Do not switch the shared review server's checkout or migrate its database to run tests.

| Configuration | File |
| --- | --- |
| Debug overrides | Ignored `Configuration/Local.xcconfig` |
| Release overrides | Ignored `Configuration/Release.local.xcconfig`, copied from its `.example` |

Both support `NODE_BINARY`, `ROOMLINGS_WEB_ROOT`, `ROOMLINGS_API_SCHEME` and `ROOMLINGS_API_HOST`.
Debug defaults to the local API; Release has no public host until configured.
Release does not inherit Debug overrides. See [invitation settings](invitations.md) and [archive safeguards](testflight.md).

The room build bundles the web renderer without copying its source into this repository.
It records the source revision and dependency lock hash, generates the native theme, and checks the shared branding assets.
Missing or incompatible web source and dependencies fail the build.

## Checks

Run the smallest checks that cover a change:

```sh
swift test --package-path Packages/RoomlingsCore
node --test Tests/Release/release.test.mjs Tests/Invitations/invitation-links.test.mjs Tests/CI/native-test-plan.test.mjs
node Scripts/build-room.mjs
node --test Tests/RoomRenderer/room-renderer.test.mjs Tests/Branding/brand-assets.test.mjs
node Scripts/test-accounts.mjs
```

Use **Product > Test** for room controls. The native account runner starts an isolated in-memory server with test identities and separate Keychain services; it does not use a real account.
Also run an ordinary Xcode build after build-configuration changes: the flow runner supplies its own `ROOMLINGS_WEB_ROOT`, so it cannot detect a stale path in local Xcode settings.

## Targeted native flows

Use `--chores-only` for chores, or repeat `--ui-test TestClass/testMethod` to select flows:

```sh
node Scripts/test-accounts.mjs \
  --ui-test AccountUITests/testWebFirstJoiningRestoresNativelyAndReopeningTheLinkDoesNotDuplicateMembership
```

All methods below belong to `AccountUITests`.

| Area | Methods |
| --- | --- |
| Shopping | `testShoppingEditsClaimsAndPicksWithoutCreatingDebt` |
| Money | `testBalancesMatchTheServerAndRepaymentsCanBeUndone` |
| Invitations | `testInvitationsShareJoinAndRejectARevokedLink`, `testInvitationsRequireRefreshAfterALostResponseAndAConflict`, `testWebFirstJoiningRestoresNativelyAndReopeningTheLinkDoesNotDuplicateMembership` |
| Notifications | `testNotificationMutesPersistAfterRelaunchWithoutPermissionOrDeliveryConfiguration` |
| Analytics | `testAnalyticsCountsForegroundVisitsButNotSheetRefreshes`, `testAnalyticsLostResponseDoesNotRetryOrHideHouseholdTools` |
| Account deletion | `testAccountDeletionRequiresExactConfirmationAndKeepsTheSharedLedger`, `testAccountDeletionPendingSurvivesRelaunchAndOffersANativeRetry` |
| Ownership | `testOwnershipTransferConfirmsTheNamedMemberAndPreservesTheLedger`, `testAnUnconfirmedOwnershipTransferMustBeRefreshedWithoutRepeatingIt` |
| Membership | `testLeavingAHouseholdPreservesOtherHomesAndRevokesItsOldAccess`, `testOwnersRemoveAccountAndBrowserAccessWithoutDeletingSharedHistory` |

## CI shards

CI covers Swift, the shared renderer and native flows on iPhone and iPad.
Each device's UI coverage is split using Xcode's compiled test inventory. Model tests run once per device, on shard 1; result bundles must contain exactly the assigned tests, all passing without skips.

```sh
node Scripts/test-accounts.mjs --include-room --shard 1/2
node Scripts/test-accounts.mjs --include-room --shard 2/2
```

Run local shards sequentially because they share build output.
Unsharded runs and individual `--ui-test` selectors are unchanged.
