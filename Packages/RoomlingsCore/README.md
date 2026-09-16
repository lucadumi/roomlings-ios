# RoomlingsCore

Local Swift 6 package for native account transport and foreground Keychain storage. iOS 18 is the minimum; macOS is declared only to run host tests. No UI, provider SDK, browser authentication or local ledger is included.

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

Tests inject `HTTPTransport` and `SessionTokenStore`; they do not use global URLProtocol state, a real server or the owner's Keychain. `SessionToken` deliberately has no public plaintext getter and redacts descriptions and mirrors.

```sh
swift test --package-path Packages/RoomlingsCore
```
