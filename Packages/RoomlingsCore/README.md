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
| `reauthenticate(accountID:code:deviceLabel:)` | `POST /api/account/verify`, bound to the restored account |
| `recover(email:recoveryCode:deviceLabel:)` | `POST /api/account/recover` |
| `restore()` | `GET /api/account` |
| `logout(allDevices:)` | `POST /api/account/logout` |
| `deleteAccount(accountID:confirmation:)` | `DELETE /api/account` |
| `finishAccountDeletionCleanup()` | Local credential cleanup only, no HTTP request |
| `createHousehold(name:memberName:currency:budgetCents:requestID:)` | `POST /api/account/households` |
| `acceptInvitation(code:memberName:)` | `POST /api/account/invitations/accept` |
| `selectHousehold(id:)` | `POST /api/account/households/<id>/select` |
| `loadInvitations(householdID:)` | `GET /api/account/households/<id>` |
| `loadHouseholdAccess(householdID:)` | The same household-access GET, including the member roster |
| `transferOwnership(to:householdID:version:accountID:)` | `POST /api/account/households/<id>/owner` |
| `removeHouseholdMember(id:householdID:version:accountID:)` | `DELETE /api/account/households/<id>/members/<memberId>` |
| `leaveHousehold(householdID:version:accountID:)` | `DELETE /api/account/households/<id>/membership` |
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

`state` starts as `nil`; state-returning operations validate server responses before updating it. Read `state`, `selectedHousehold`, `deletionStatus`, `pendingHouseholdDeparture` and `isBusy` with `await`. A confirmed remote deletion clears cached private state even if local credential cleanup still needs retry.

- Share one coordinator per Keychain entry. Overlapping account operations throw `AccountError.operationInProgress`, including while credential storage is suspended. Analytics uses a separate non-mutating path so it cannot block those operations. Nothing automatically retries mutations.
- Creation takes integer cents. Reuse the same `requestID` and details for an explicit retry.
- Invitations accept raw account codes or web links containing `#account-invite=<encoded code>`. Links are parsed locally, never opened.
- A replacement bearer is saved before a new signed-in state is published. Verification and recovery include the current bearer so only that device rotates.
- Confirmed signed-out account responses and `401 ACCOUNT_SESSION_REQUIRED` from account operations clear the credential. The latter clears `state` to `nil` and still throws the server error. Analytics failures never alter credentials. Network failures, invalid input/responses, other HTTP errors, reauthentication requirements and pending deletion do not erase the credential.
- `deletionPending` states contain no household access. A `409` or `503 ACCOUNT_DELETION_PENDING` is a failure, not completed deletion. An explicit `restore()` obtains the server's deletion-only state; the native deletion flow can retry it without reopening household access.
- Failed credential operations throw. Do not present a caught error as success. A failed replacement leaves the previous Keychain item intact, but that old server session may already have rotated; obtain a fresh email or unused recovery code rather than replaying a consumed code.
- `AccountError.server(status:code:)` retains only the status and a known `AccountServerCode`, never server messages. `KeychainError.status(operation:status:)` retains the failing OSStatus. Unknown storage/transport errors are sanitized.

`Account`, `AccountMembership`, `AccountDevice`, `AccountKitchenSession`, `AccountState` and `HouseholdSnapshot` are Sendable/Codable values. Timestamps retain validated UTC ISO 8601 strings. The household's `value: JSONValue` preserves supplied data without synthesizing empty collections. Metadata and collection envelopes are checked, not the complete TypeScript ledger schema. Integer values use `Int64`; out-of-range integral JSON fails rather than silently rounding through floating point. `csrfToken` is validated and private, and `session.token` must be null. State encoding preserves the backend contract, so do not send an entire encoded account state to JavaScript. Give a renderer only its intended household/room data.

`APIConfiguration` accepts only origin URLs, HTTPS or exact loopback HTTP. `URLSessionTransport` is ephemeral, disables cookies, credentials and cache, has finite timeouts, and rejects every redirect. Requests always identify the native client and never use browser/CSRF headers. Bearers exist only in native requests and `SessionTokenStore`.

## Account deletion

**Account > Account lifecycle > Delete my account** opens a confirmation page inside the existing sheet. The email must exactly match the restored account, with no trimming or case normalization. The request is bound to that account UUID and current native credential, not merely to whichever account happens to be signed in later.

The server requires a sign-in within the last ten minutes and enforces ownership handoff. **Verify email again** sends a code to the current account and rotates only that native session. The response must still belong to the same account before its credential is saved. Verification never automatically sends deletion; the user reviews the warning and enters the email again. Push registration is renewed for the rotated session without losing account-bound consent.

An owner with other active roommates must transfer ownership first in **Account > Household members**. **Manage household ownership** returns from the deletion form to Account, where the owner can select each household needing a handoff. A sole owner can close household access. Deletion does not cancel debts, remove shared ledger records or scrub names embedded in descriptions. The server pseudonymizes former-roommate display names while retaining the financial references needed for correct balances.

`AccountDeletionStatus` separates these outcomes:

| Status | Native behavior |
| --- | --- |
| `none` | No unresolved deletion attempt. A rejected confirmation, recent-sign-in check or ownership handoff leaves the account usable. |
| `unconfirmed` | A response was lost or unusable, or access ended without proof of deletion. Household tools and further deletion attempts stay blocked until an explicit account refresh. |
| `pending` | The server has disabled access and is retrying provider deletion. Account shows **Check deletion status** and **Retry account deletion**, including after relaunch. |
| `localCleanupRequired` | The server confirmed deletion, but Keychain cleanup failed or was interrupted. **Clear saved access** retries local cleanup without repeating the DELETE. A replacement credential is never erased. |
| `completed` | The server acknowledged deletion and the session credential was cleared. The app also clears matching account-bound push consent before reporting the flow complete. |

The client does not automatically repeat deletion requests. A signed-out refresh after an unconfirmed request proves only that access ended, not that the provider identity was deleted. Pending deletions continue on the server even if the user signs out.

Deletion and reauthentication share the account operation gate. During unresolved deletion, `selectedHousehold` is unavailable and other account mutations and analytics cannot use stale household access. The app clears room projections, pending invitations and notification targets as appropriate; local cleanup failures remain visible rather than being reported as a successful save.

All automated deletion journeys use an isolated in-memory server, a fake identity provider and separate test Keychain services. They never call deletion on the shared preview API or Supabase.

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
- Closing Account cancels its notification-preference read without marking the household as failed. Genuine read failures and unconfirmed preference writes still show an error; cancelling a read neither claims the settings were loaded nor clears an earlier failure.
- Delivery needs a reachable notification backend with APNs credentials. Mocks and injected payloads verify app flows and contracts, not real APNs delivery. Some newer Apple Silicon simulator runtimes support APNs, but issue acceptance explicitly requires proof on a properly provisioned real device.

## Household ownership

**Account > Household members** loads the selected household's current roster. Each member retains their server ID, name, role, active status and account-link status. The existing `HouseholdInvitationAccess` response now validates this roster against the household snapshot; `loadInvitations` and `loadHouseholdAccess` use the same endpoint and cached model data.

Only the owner sees **Make owner**, and only beside another active, account-linked roommate. Browser-only identities and former roommates remain visible but cannot receive ownership. A native confirmation names the recipient and explains that the current owner stays a member, that the ledger is unchanged, and that only the new owner can transfer ownership back. Native popovers can be cancelled by tapping outside them.

The confirmation captures the account UUID, household, member and household version. Transferring sends only `{ memberId, version }` with the native bearer. The server rechecks current ownership, target eligibility and the optimistic version inside its transaction. Admin permissions never grant the ability to transfer ownership.

A valid response must confirm the requested new owner, the previous owner's member role and the next household version. The native session updates both its household snapshot and matching membership role without replacing credentials or other households. Invitation links and owner-only invitation history are cleared when authority is lost. No balances are recalculated locally.

After a conflict, denied access or uncertain response, refresh household members before another handoff. This endpoint has no replay receipt, and the client never automatically retries it. Refreshing after a lost response can reveal that the handoff already succeeded without falsely presenting the lost acknowledgment as a confirmed save.

Switching accounts or households discards the cached roster and confirmation. Every operation shares the account gate and checks the credential again before publishing a response; a late response cannot clear a replacement credential. No domain setup, third-party service or new database schema is needed.

### Leaving and removing access

**Leave household** appears beneath the roster. Owners with other active roommates must transfer ownership first. A sole owner can close the household to new access. The confirmation names the household and explains that debts and history remain; leaving never deletes the Roomlings account.

Only the owner sees **Remove access** beside other active roommates, including browser-only identities. The owner cannot remove themselves through that control. The confirmation names the roommate and distinguishes removing household access from deleting their account.

Both requests capture the intended account UUID, selected household and optimistic version. Removal must return the same owner with the target still present but inactive and the next household version. Leaving must return the same account and native session with no membership in that household and no selected household. Other memberships and the stored account credential remain intact.

The server retains financial records and member IDs, releases the departing member's shopping claims and basket flags, and revokes their household access through account membership, browser sessions and recovery codes. Existing invitations cannot restore a removed account membership; a new owner-issued invitation is required. Future bill participants still need review with the household.

Failures are not treated as successful departures or removals. Stale or uncertain removals require a roster refresh. An interrupted or unusable leave response sets `pendingHouseholdDeparture`; the app hides the old room and household tools and offers **Refresh account**. Until that read resolves current membership, the coordinator rejects further changes and analytics against stale access. Refreshing resolves access without automatically repeating the DELETE or falsely claiming an acknowledgment was received.

Successful leaving returns to Account to choose another household. Pending notification taps for a household whose membership ended are discarded, and deferred preference reads for that old selection are cancelled. The account's notification installation remains available for its other households.

## Invitations

- Invitation management remains **owner-only**, matching the shared server. Admins and members ask the owner for a link. Revoking a link never removes people who already joined.
- The household access GET returns the member roster and invitation metadata, not reusable codes. Creation returns a case-sensitive code once and a seven-day expiry. Used links remain pending until revoked or expired. Invitation timestamps are validated UTC dates.
- Create and revoke send the household `version`. These routes have no mutation receipt or automatic retry. After a conflict or uncertain response, refresh before another change. If a creation response was lost, revoke that pending invitation and create a new one; its original code cannot be retrieved.
- `AccountInvitationCode` reuses the existing local fragment parser and redacts descriptions and mirrors. Incoming app links must match the configured invitation origin. Manually pasted links still extract only the code; requests always go to the configured native API, never the pasted host.
- **Account** shares the invitation as a single URL through `UIActivityViewController`, so the system **Copy** action pastes the full link without a separate message. Completion is observed for analytics without inspecting the destination or returned items. Outgoing links are kept only in memory and discarded when Account closes, the household/account changes, or the link is revoked. Invitations and session credentials never enter the room renderer.
- Incoming invitations stay in memory through native sign-in, recovery and failed joins. Joining always requires confirmation. Another room sheet can finish before the invitation opens. If the process closes, reopen the original link.

### Local use

With the local API and web preview running, open **Account** as the household owner, create an invitation and share or copy its link. A second account can paste it into **Join a household** in the native app, or use the existing web join flow.

The default `http://localhost:5173` link is for the same Mac and its simulators, not another physical device. It does not open the native app automatically. Keep using the paste-to-join flow until the public domain and Universal Links are configured.

### Public link setup

**The public domain is not chosen yet.** Universal Links are opt-in through `ROOMLINGS_UNIVERSAL_LINKS`; the default `NO` keeps the original push-only entitlements. An invitation origin alone does not enable app-opening links.

`ROOMLINGS_INVITATION_SCHEME` and `ROOMLINGS_INVITATION_HOST` configure the web origin, separately from the API. Debug defaults to `http://localhost:5173`; Release leaves the host blank. Missing configuration is shown explicitly, and no new share link is offered.

`AccountInvitationCode(link:origin:)` accepts incoming URLs only at the configured origin's root, without a query or extra fragment parameters. The general string initializer remains suitable for explicit paste-to-join. Neither opens the supplied URL.

See [invitation configuration](../../docs/invitations.md) for the optional entitlement, generated association file and signing checks. The not-installed flow is web-first: join in the browser, then sign into the same account in the app. No invitation is transferred through installation, and browser sessions remain intact.

### Invitation flows

The [targeted native flows](../../docs/development.md#targeted-native-flows) use the real shared server with isolated test accounts, including cookie-based web acceptance without invalidating the browser session. A DEBUG-only launch input drives the same native URL handler for signed-out and restored launches. Physical-device domain association remains a separate acceptance step.

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
