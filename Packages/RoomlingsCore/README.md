# RoomlingsCore

Local Swift 6 package for native accounts, household chores, shopping, the shared money ledger, notifications and retention events. iOS 18 is the minimum; macOS is declared only to run host tests. No UI, provider SDK, browser authentication or local ledger arithmetic beyond the shared split preview is included.

Link the `RoomlingsCore` library from `Packages/RoomlingsCore` in the Xcode project:

```swift
import RoomlingsCore

let configuration = try APIConfiguration(origin: "https://your-roomlings-server.example")
let credentials = try KeychainSessionTokenStore(
    service: "your.app.bundle-id.account",
    account: "account-session"
)
let accounts = AccountSession(configuration: configuration, tokenStore: credentials)
```

Creating these objects performs no network or Keychain operations. Supply the app's actual non-secret API origin and a stable, app-specific Keychain service. The native backend contract is included in the web repository's `main` branch. Point this package at a running server that includes the native-session feature; a source merge does not itself restart or deploy the server.

## Entry points

All operations are explicit, asynchronous and throwing:

| `AccountSession` operation | Request |
| --- | --- |
| `sendEmailCode(email:)` | `POST /api/account/code` |
| `verifyEmailCode(email:code:name:deviceLabel:)` | `POST /api/account/verify` |
| `recover(email:recoveryCode:deviceLabel:)` | `POST /api/account/recover` |
| `restore()` | `GET /api/account` |
| `logout(allDevices:)` | `POST /api/account/logout` |
| `createHousehold(name:memberName:currency:budgetCents:requestID:)` | `POST /api/account/households` |
| `acceptInvitation(code:memberName:)` | `POST /api/account/invitations/accept` |
| `selectHousehold(id:)` | `POST /api/account/households/<id>/select` |
| `loadInvitations(householdID:)` | `GET /api/account/households/<id>` |
| `createInvitation(householdID:version:)` | `POST /api/account/households/<id>/invitations` |
| `revokeInvitation(id:householdID:version:)` | `DELETE /api/account/households/<id>/invitations/<id>` |
| `loadNotificationSettings(householdID:)` | `GET /api/account/households/<id>/notifications` |
| `saveNotificationSettings(_:householdID:)` | `PUT /api/account/households/<id>/notifications` |
| `registerPushDevice(installationID:token:environment:)` | `PUT /api/account/push-devices` |
| `unregisterPushDevice(installationID:)` | `DELETE /api/account/push-devices/<installationId>` |
| `recordAnalytics(_:context:)` | `POST /api/account/households/<id>/analytics` |
| `addChore(_:householdID:version:mutationID:)` | `POST /api/chores` |
| `completeChore(id:choreVersion:householdID:version:mutationID:)` | `POST /api/chores/<id>/complete` |
| `undoChoreCompletion(id:choreVersion:householdID:version:mutationID:)` | `POST /api/chores/completions/<id>/undo` |
| `addShoppingItem(_:householdID:version:mutationID:)` | `POST /api/shopping/items` |
| `editShoppingItem(id:draft:itemVersion:householdID:version:mutationID:)` | `PATCH /api/shopping/items/<id>` |
| `removeShoppingItem(id:itemVersion:householdID:version:mutationID:)` | `DELETE /api/shopping/items/<id>` |
| `claimShoppingItem(id:claim:itemVersion:householdID:version:mutationID:)` | `POST /api/shopping/items/<id>/claim` |
| `pickShoppingItem(id:pickedUp:itemVersion:householdID:version:mutationID:)` | `POST /api/shopping/items/<id>/pick` |
| `recordExpense(_:householdID:version:mutationID:)` | `POST /api/expenses` |
| `checkoutShopping(_:checkoutID:selection:householdID:version:mutationID:)` | `POST /api/shopping/checkout` |
| `removeExpense(id:householdID:version:mutationID:)` | `DELETE /api/expenses/<id>` |
| `recordSettlement(from:to:amount:householdID:version:mutationID:)` | `POST /api/settlements` |
| `removeSettlement(id:householdID:version:mutationID:)` | `DELETE /api/settlements/<id>` |

`state` starts as `nil`; successful state-returning operations validate and update it. Read `state`, `selectedHousehold` and `isBusy` with `await`.

- Share one coordinator per Keychain entry. Overlapping account operations throw `AccountError.operationInProgress`, including while credential storage is suspended. Analytics uses a separate non-mutating path so it cannot block those operations. Nothing automatically retries mutations.
- Creation takes integer cents. Reuse the same `requestID` and details for an explicit retry.
- Invitations accept raw account codes or web links containing `#account-invite=<encoded code>`. Links are parsed locally, never opened.
- A replacement bearer is saved before a new signed-in state is published. Verification and recovery include the current bearer so only that device rotates.
- Confirmed signed-out account responses and `401 ACCOUNT_SESSION_REQUIRED` from account operations clear the credential. The latter clears `state` to `nil` and still throws the server error. Analytics failures never alter credentials. Network failures, invalid input/responses, other HTTP errors, reauthentication requirements and pending deletion do not erase the credential.
- `deletionPending` states contain no household access. A `409` or `503 ACCOUNT_DELETION_PENDING` is a failure, not completed deletion. After such a failure, an explicit `restore()` obtains the server's deletion-only state. This initial package does not implement deletion.
- Failed credential operations throw. Do not present a caught error as success. A failed replacement leaves the previous Keychain item intact, but that old server session may already have rotated; obtain a fresh email or unused recovery code rather than replaying a consumed code.
- `AccountError.server(status:code:)` retains only the status and a known `AccountServerCode`, never server messages. `KeychainError.status(operation:status:)` retains the failing OSStatus. Unknown storage/transport errors are sanitized.

`Account`, `AccountMembership`, `AccountDevice`, `AccountKitchenSession`, `AccountState` and `HouseholdSnapshot` are Sendable/Codable values. Timestamps retain validated UTC ISO 8601 strings. The household's `value: JSONValue` preserves supplied data without synthesizing empty collections. Metadata and collection envelopes are checked, not the complete TypeScript ledger schema. Integer values use `Int64`; out-of-range integral JSON fails rather than silently rounding through floating point. `csrfToken` is validated and private, and `session.token` must be null. State encoding preserves the backend contract, so do not send an entire encoded account state to JavaScript. Give a renderer only its intended household/room data.

`APIConfiguration` accepts only origin URLs, HTTPS or exact loopback HTTP. `URLSessionTransport` is ephemeral, disables cookies, credentials and cache, has finite timeouts, and rejects every redirect. Requests always identify the native client and never use browser/CSRF headers. Bearers exist only in native requests and `SessionTokenStore`.

## Retention analytics

The server already timestamps chore, expense and repayment mutations. Its session `last_used_at` is overwritten, so it cannot reconstruct historical app opens. The native client sends only these missing signals to Roomlings' own endpoint:

| Event | Recorded when |
| --- | --- |
| `app_opened` | The app enters the foreground and an authenticated household is available, once per account/device/selected household in that visit. Returning from an inactive system overlay or refreshing a sheet does not count again. |
| `notification_opened` | A notification tap finishes authentication, household authorization and successful navigation to an existing target. Receiving a push, a rejected target or an unfinished sign-in does not count. |
| `invite_shared` | The system share sheet confirms a completed action, including Copy. Opening or cancelling the sheet does not count. |
| `invite_accepted` | The server confirms joining a household that was not already in the account's memberships. Failed joins and reopening an already-accepted link do not count. |

`AnalyticsEvent` encodes only `kind`, UTC `occurredAt` and Gregorian `localDate` in the device's time zone. Household identity is in the request path; the server derives the member from its authenticated session. `AnalyticsContext` binds pending work to the account, current account-session/device, household and member but is never serialized. No names, amounts, invitation links, notification contents, device tokens or credentials enter event bodies, logs or the room bridge.

Delivery is best effort and does not block sign-in, sign-out, household changes or ledger saves. Only in-memory work is kept, capped at 50 in-flight events and cancelled when its identity changes. There is no disk queue or automatic retry. The server aggregates daily members but increments occurrences for every accepted request, so retrying an uncertain response could overcount. Failures are logged with a fixed diagnostic category, never shown as failed household actions, and never clear or replace a credential.

The server retains per-member/kind/day aggregates for 30 days. For a known test household and day-7 date, the operator can count opens without exporting identities:

```sql
SELECT COUNT(DISTINCT member_id)
FROM analytics_events
WHERE household_id = :household_id AND kind = 'app_opened' AND local_date = :day_7;
```

These are observed opens, not proof of every visit: offline or unconfirmed requests can be missed. The isolated tests exercise real persisted aggregates and a simulated week; they do not replace collecting a real cohort's week of events.

Use the web revision pinned in CI for both build and test harness. The analytics API requires the server's schema-5-compatible build; this client does not migrate or restart any shared database. An older server's missing endpoint is a logged analytics failure, not a reason to hide the household tools.

## Notifications

- `NotificationPreferences(chores:money:)` belongs to the current household member on the server. Preferences survive app reinstall and are independent of the household ledger version. Settings requests require the intended selected household and an active member; successful responses never replace account or ledger state.
- Device registration requires a confirmed native account and bearer, but no selected household. It sends the installation UUID, `APNsDeviceToken` and explicit `.sandbox` or `.production` environment. The server binds registration to that account session/device and invalidates it on logout, revocation or account deletion.
- All four calls share the account operation gate and confirmed-expiry handling. Response types, household/member identity and true registration/removal acknowledgments are required. Credential changes during a request prevent success; failures preserve good local state. No request is automatically retried.
- `pushAvailable` reports provider availability. `503 PUSH_NOT_CONFIGURED` becomes `AccountServerCode.pushNotConfigured`, not a successful registration. Preferences can still be read or saved when delivery is unavailable.
- The app must offer an explicit **Enable** action before requesting OS notification permission. `PushInstallation(id:enabled:accountID:)` stores a stable random installation ID, that device's explicit opt-in and an optional account binding, never an APNs token. Enable binds the current account; automatic registration requires `enabled` and a matching signed-in `accountID`. Missing or null account bindings remain unbound, including old stored records. Disable stores `enabled: false, accountID: nil` without rotating the installation ID.
- `KeychainPushInstallationStore(service:account:)` defaults to account `"push-installation"`; use the existing app/API-origin-scoped Keychain service with that separate account name.
- Installation storage uses atomic update/add with duplicate-item retry, `WhenUnlockedThisDeviceOnly` and no synchronization. Missing storage returns `nil`; locked, corrupt or failed storage throws. Do not turn storage failures into a new installation or a successful opt-in.
- APNs tokens accept nonempty, even-length ASCII hex from 2 through 1,024 characters, or 1 through 512 bytes. Serialization is internal, and descriptions and mirrors redact them. Tokens, credentials and registration bodies must never enter logs or the room renderer.
- Decode `NotificationDestination` from only the custom `roomlings` object, not the outer APNs payload. Its `target: NotificationDestination.Target` supports `.chores(componentID:)`, `.expense(UUID)` and `.settlement(UUID)` in version `1`. Chores may omit `componentId`; money routes require their own UUID. Unknown fields, URLs, versions and malformed identifiers are rejected. The app must restore account access and validate the target household and item before navigating.
- Approved delivery policy is a daily **09:00** reminder for due assigned chores in the household time zone, plus immediate expense and repayment notifications to other members. Notification text remains generic. Scheduling and recipient preferences are server-owned.

### App setup and delivery validation

- **Account** exposes household chore/money switches and an explicit **Enable notifications** action. The app never prompts for notification permission on startup.
- `RoomlingsAPNsEnvironment` reads `ROOMLINGS_APNS_ENVIRONMENT`: `development` in Debug maps to APNs sandbox, while `production` in Release uses production APNs. TestFlight uses production.
- The app target has the **Push Notifications** capability. `Roomlings/Roomlings.entitlements` is applied only for the iPhoneOS SDK. Provisioned signing must include the corresponding push entitlement and APNs topic `com.roomlings.app`.
- Startup registers fresh tokens only for the matching opted-in account. APNs tokens are never stored on disk; the installation Keychain entry stores only the installation UUID, `enabled` flag and `accountID`.
- Delivery needs a reachable notification backend with APNs credentials. Mocks and injected payloads verify app flows and contracts, not real APNs delivery. Some newer Apple Silicon simulator runtimes support APNs, but issue acceptance explicitly requires proof on a properly provisioned real device.

## Invitations

- Invitation management remains **owner-only**, matching the shared server. Admins and members ask the owner for a link. Revoking a link never removes people who already joined.
- The household access GET returns invitation metadata, not reusable codes. Creation returns a case-sensitive code once and a seven-day expiry. Used links remain pending until revoked or expired. Invitation timestamps are validated UTC dates.
- Create and revoke send the household `version`. These routes have no mutation receipt or automatic retry. After a conflict or uncertain response, refresh before another change. If a creation response was lost, revoke that pending invitation and create a new one; its original code cannot be retrieved.
- `AccountInvitationCode` reuses the existing local fragment parser and redacts descriptions and mirrors. Incoming app links must match the configured invitation origin. Manually pasted links still extract only the code; requests always go to the configured native API, never the pasted host.
- **Account** shares the invitation as a single URL through `UIActivityViewController`, so the system **Copy** action pastes the full link without a separate message. Completion is observed for analytics without inspecting the destination or returned items. Outgoing links are kept only in memory and discarded when Account closes, the household/account changes, or the link is revoked. Invitations and session credentials never enter the room renderer.
- Incoming invitations stay in memory through native sign-in, recovery and failed joins. Joining always requires confirmation. Another room sheet can finish before the invitation opens. If the process closes, reopen the original link.

### Local use

With the local API and web preview running, open **Account** as the household owner, create an invitation and share or copy its link. A second account can paste it into **Join a household** in the native app, or use the existing web join flow.

The default `http://localhost:5173` link is for the same Mac and its simulators, not another physical device. It does not open the native app automatically. Keep using the paste-to-join flow until the public domain and Universal Links are configured.

### Public link setup

**The public domain is not chosen yet.** The native URL handler is implemented, but no Associated Domains entitlement or deployed `apple-app-site-association` file is configured. Setting an origin alone does not enable Universal Links.

`ROOMLINGS_INVITATION_SCHEME` and `ROOMLINGS_INVITATION_HOST` configure the web origin in `Configuration/Local.xcconfig` for Debug or `Configuration/Release.local.xcconfig` for Release. Debug defaults to `http://localhost:5173`; Release leaves the host blank. Missing configuration is shown explicitly, and no new share link is offered. The web origin may differ from the API origin. Distribution archives require both public HTTPS origins; see the [TestFlight guide](../../docs/testflight.md).

After choosing the HTTPS domain and signing identity:

1. Serve the existing web app at that origin and configure the invitation settings to match.
2. Add the Associated Domains capability to the app target with `applinks:<chosen-domain>`, using a provisioning profile with that entitlement.
3. Serve `/.well-known/apple-app-site-association` as JSON over HTTPS, without authentication or redirects. Replace the app ID prefix below with the signed app's actual prefix:

```json
{
  "applinks": {
    "details": [{
      "appIDs": ["APP_ID_PREFIX.com.roomlings.app"],
      "components": [{"/": "/", "#": "account-invite=roomlings-invite-*"}]
    }]
  }
}
```

The fragment rule targets generated invitation links without intercepting unrelated web account or recovery URLs. See Apple's [association format](https://developer.apple.com/documentation/bundleresources/applinks) and [SwiftUI URL handler](https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)).

Without the app, the link opens the existing web join flow. Either join there and later sign into the same native account, or install the app and reopen the original message's link. Universal Links do not automatically transfer a pending invitation through installation. No clipboard scanning or install tracking is used.

### Invitation flows

```sh
node Scripts/test-accounts.mjs \
  --ui-test AccountUITests/testInvitationsShareJoinAndRejectARevokedLink \
  --ui-test AccountUITests/testInvitationsRequireRefreshAfterALostResponseAndAConflict \
  --ui-test AccountUITests/testWebFirstJoiningRestoresNativelyAndReopeningTheLinkDoesNotDuplicateMembership
```

The isolated flows use the real shared server with test accounts and exercise cookie-based web acceptance without invalidating that browser session. A DEBUG-only launch input drives the same native URL handler for signed-out and restored launches. These flows do not verify Apple's domain association. Before closing the Universal Links work, verify signed-device links from Messages with the app installed and absent, including revoked links and both installation paths.

## Chores

- `try HouseholdChores(household:)` projects typed `items`, `history`, `members` and `activeMembers`. `assignee(for:)` skips inactive roommates; `isPaused(_:)` follows shared object storage rules. Malformed data throws; the raw household is never rewritten.
- `billingTimeZone` keeps the original identifier; `timeZone` resolves named zones and fixed offsets through 23:59. Case-insensitive IANA aliases use platform Intl with only the identifier, never account data or credentials. Only an absent field defaults to UTC, never the device's time zone.
- `try ChoreDraft(title:notes:roomID:area:componentID:dueDate:repeatDays:rotation:turn:)` validates the shared input limits. Room/area IDs are web strings; component IDs are slugs, not UUIDs. Dates are `YYYY-MM-DD`; timestamps retain UTC strings. `Chore.status(on:)` compares a supplied household-local calendar date. Only the server advances schedules, rotation and history.
- Mutations require the intended selected household, an active roommate and its restored native account credential. Any active roommate may complete, not only the assignee. Successful responses replace only the validated selected household, preserving unknown JSON and integer values.
- Keep the original draft/chore version, household `version` and `mutationID` for explicit retries, even after `restore()` refreshes the household. Both `version` and `mutationVersion` carry that original version. Nothing automatically retries. HTTP 409 and `mutationIDConflict`, `mutationPayloadChanged`, `mutationTooOld` remain explicit failures.
- `accountStateRequired` or `householdSelectionChanged` requires reviewing/restoring the current account or home. Chores share the account/credential operation gate and existing expiry/storage failure handling. No separate chores GET is needed.
- `canUndo(_:)` requires a retained completion and the server's matching chore version and occurrence, regardless of history order or assignee. Later edits, completions, archiving and replaced history invalidate older completion values. Completed one-offs and stored object chores can still be undone.
- Undo uses the completion's `resultVersion` as `choreVersion`; only the server restores its date, turn and occurrence. The response must confirm that completion and the current roommate's undo. Explicit retries retain the original versions and mutation ID, even after refresh; replay responses may include later chore changes and are never rolled back locally.

## Shopping

- `try HouseholdShopping(household:)` projects `items`, `members` and `activeMembers` from the restored account snapshot, without another GET. `HouseholdShopping.itemLimit` is 200. `HouseholdMember` is shared with the existing `ChoreMember` alias. Only absent shopping, quantity and notes receive the shared defaults.
- `try ShoppingDraft(name:quantity:notes:)` trims like the web and validates 50/40/240 UTF-16 units. Quantity defaults to `"1"` and notes to `""`. Ordinary additions allow duplicate names.
- `claimOwner(for:)` uses member IDs, retaining inactive owners and duplicate display names. `canEdit(_:memberID:)`, `canClaim(_:claim:memberID:)` and `canPick(_:pickedUp:memberID:)` describe available new actions for active roommates. `inBasket(_:memberID:)` matches shared basket membership.
- Any active roommate may release anyone's claim; release also unpicks. Picking claims an unclaimed item. Unpicking keeps its owner. Another shopper's claim blocks edits, removal and picking. Repeating a claim/basket status without a receipt returns 409, not a successful no-op.
- All mutations return `AccountState` and share account serialization, native bearer transport and credential failure handling. Retain the original draft, `itemVersion`, household `version` and `mutationID` for explicit retries, including after `restore()`. The request's `mutationVersion` remains that original household version.
- Success requires a validated household and the original mutation receipt. Fresh saves must confirm the requested change; replay responses may contain later edits or no remaining target item. Current local item eligibility never blocks sending an explicit replay.
- `ShoppingItem.componentSources` preserves embedded `ShoppingComponentSource` labels, including stored or renamed objects. Raw unknown data and shopping history remain server-owned. No optimistic ownership changes or restocking API is included.

## Ledger

- `try HouseholdLedger(household:)` projects `expenses`, `settlements`, `members` and `activeMembers` from the restored snapshot, without another GET. There is no expenses or settlements GET, and no expense edit route; the server returns the whole household. `HouseholdLedger.expenseLimit` is 20,000.
- `try ExpenseDraft(description:amount:paidBy:participants:category:date:)` mirrors the shared expense schema: trimmed 1 to 100 character description, whole cents from 1 to 100,000,000, a payer and 1 to 12 unique participants, a `produce`/`dairy`/`pantry`/`drinks`/`other` category and a `YYYY-MM-DD` date.
- Money is `Int64` cents everywhere. `shares` mirrors the web `splitAmount`: participants sort by member ID, everyone takes `amount / count`, and the remaining cents go one each to the first sorted IDs, so the shares always total the amount. It only previews what the server records.
- `checkoutShopping` sends each selected item's current `version`; the server records one expense, files a shopping run and removes exactly those items. Reuse the same `checkoutID` and `mutationID` for an explicit retry so a replay cannot record a second run.
- Responses must confirm the mutation receipt and the expected ledger. A fresh save must show the new expense first, unchanged remaining expenses, and for a checkout exactly the selected items removed plus the new run. Replays may contain later changes.
- `canRemove(_:memberID:)` covers only plain expenses. Shopping receipts and bill payments belong to the flow that created them and are removed on the web, so run history stays consistent. Removal is not an edit; the server has no expense edit route.

## Balances and repayments

- `balances` and `suggestedTransfers` mirror the same functions in the web project's `shared/domain.ts`, so the app can never display a figure the server would contradict. There is no balances endpoint; both sides derive them from the shared ledger.
- A balance is whole cents and positive when the household owes that member. A payer is credited the whole amount, each participant is debited their whole-cent share, and a repayment credits the member who paid it back. Balances always total zero.
- `suggestedTransfers` settles the largest debtor against the largest creditor until one is square, breaking ties by member ID exactly as the shared sort does. Applying every suggestion leaves everyone at zero.
- `canSettle(from:to:amount:)` repeats the server's own guard rails: the payer must owe, the recipient must be owed, and the amount cannot exceed either side. A repayment outside them is a `409` telling the member to use the updated suggestion.
- `recordSettlement` sends only `from`, `to` and `amount`; the server generates the identifier and timestamp and unshifts it. `removeSettlement` undoes one and puts the amount back on the balances. Neither moves money, and the app never claims to.
- Settlement responses are verified like every other mutation: the receipt must confirm it, the expenses and shopping list must be untouched, and the repayment must be the one that was requested.

Tests inject `HTTPTransport` and `SessionTokenStore`; they do not use global URLProtocol state, a real server or the owner's Keychain. `SessionToken` deliberately has no public plaintext getter and redacts descriptions and mirrors.

```sh
swift test --package-path Packages/RoomlingsCore
```
