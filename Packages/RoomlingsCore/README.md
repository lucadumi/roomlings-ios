# RoomlingsCore

Local Swift 6 package for native accounts, household chores, shopping and the shared money ledger. iOS 18 is the minimum; macOS is declared only to run host tests. No UI, provider SDK, browser authentication or local ledger arithmetic beyond the shared split preview is included.

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

`state` starts as `nil`; successful state-returning operations validate and update it. Read `state`, `selectedHousehold` and `isBusy` with `await`.

- Share one coordinator per Keychain entry. Overlapping operations throw `AccountError.operationInProgress`, including while credential storage is suspended. Nothing automatically retries mutations.
- Creation takes integer cents. Reuse the same `requestID` and details for an explicit retry.
- Invitations accept raw account codes or web links containing `#account-invite=<encoded code>`. Links are parsed locally, never opened.
- A replacement bearer is saved before a new signed-in state is published. Verification and recovery include the current bearer so only that device rotates.
- Confirmed signed-out account responses and `401 ACCOUNT_SESSION_REQUIRED` clear the credential. The latter clears `state` to `nil` and still throws the server error. Network failures, invalid input/responses, other HTTP errors, reauthentication requirements and pending deletion do not erase the credential.
- `deletionPending` states contain no household access. A `409` or `503 ACCOUNT_DELETION_PENDING` is a failure, not completed deletion. After such a failure, an explicit `restore()` obtains the server's deletion-only state. This initial package does not implement deletion.
- Failed credential operations throw. Do not present a caught error as success. A failed replacement leaves the previous Keychain item intact, but that old server session may already have rotated; obtain a fresh email or unused recovery code rather than replaying a consumed code.
- `AccountError.server(status:code:)` retains only the status and a known `AccountServerCode`, never server messages. `KeychainError.status(operation:status:)` retains the failing OSStatus. Unknown storage/transport errors are sanitized.

`Account`, `AccountMembership`, `AccountDevice`, `AccountKitchenSession`, `AccountState` and `HouseholdSnapshot` are Sendable/Codable values. Timestamps retain validated UTC ISO 8601 strings. The household's `value: JSONValue` preserves supplied data without synthesizing empty collections. Metadata and collection envelopes are checked, not the complete TypeScript ledger schema. Integer values use `Int64`; out-of-range integral JSON fails rather than silently rounding through floating point. `csrfToken` is validated and private, and `session.token` must be null. State encoding preserves the backend contract, so do not send an entire encoded account state to JavaScript. Give a renderer only its intended household/room data.

`APIConfiguration` accepts only origin URLs, HTTPS or exact loopback HTTP. `URLSessionTransport` is ephemeral, disables cookies, credentials and cache, has finite timeouts, and rejects every redirect. Requests always identify the native client and never use browser/CSRF headers. Bearers exist only in native requests and `SessionTokenStore`.

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

- `try HouseholdLedger(household:)` projects `expenses`, `members` and `activeMembers` from the restored snapshot, without another GET. There is no expenses GET or edit route; the server returns the whole household. `HouseholdLedger.expenseLimit` is 20,000.
- `try ExpenseDraft(description:amount:paidBy:participants:category:date:)` mirrors the shared expense schema: trimmed 1 to 100 character description, whole cents from 1 to 100,000,000, a payer and 1 to 12 unique participants, a `produce`/`dairy`/`pantry`/`drinks`/`other` category and a `YYYY-MM-DD` date.
- Money is `Int64` cents everywhere. `shares` mirrors the web `splitAmount`: participants sort by member ID, everyone takes `amount / count`, and the remaining cents go one each to the first sorted IDs, so the shares always total the amount. It only previews what the server records.
- `checkoutShopping` sends each selected item's current `version`; the server records one expense, files a shopping run and removes exactly those items. Reuse the same `checkoutID` and `mutationID` for an explicit retry so a replay cannot record a second run.
- Responses must confirm the mutation receipt and the expected ledger. A fresh save must show the new expense first, unchanged remaining expenses, and for a checkout exactly the selected items removed plus the new run. Replays may contain later changes.
- `canRemove(_:memberID:)` covers only plain expenses. Shopping receipts and bill payments belong to the flow that created them and are removed on the web, so run history stays consistent. Removal is not an edit; the server has no expense edit route.
- Balances, settlements and suggested transfers stay server-owned and are not computed here.

Tests inject `HTTPTransport` and `SessionTokenStore`; they do not use global URLProtocol state, a real server or the owner's Keychain. `SessionToken` deliberately has no public plaintext getter and redacts descriptions and mirrors.

```sh
swift test --package-path Packages/RoomlingsCore
```
