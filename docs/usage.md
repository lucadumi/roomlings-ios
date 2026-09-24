# Using Roomlings

## Household and room

Sign in or recover access, then create or join a household to open its saved kitchen.
The room adapts to either orientation. Zoom includes object focus; **Reset room view** returns to 100%.

| Control | What it does |
| --- | --- |
| **Chores** or an object's **+** marker | View, add, complete and undo tasks with shared schedules and rotations. |
| **Shopping** | Add, edit, claim and pick up items. Record a paid receipt to split its cost in the shared ledger. Picking up an item alone creates no debt. |
| **Money** | View receipts, balances and repayments. Roomlings tracks money; it never moves it. |
| Household name or avatar | Open **Account**. |

## Account

| Section | What it does |
| --- | --- |
| Invitations | Owners share seven-day invitations and revoke pending links. See [invitation setup](invitations.md). |
| **Household members** | View roommates, transfer ownership, remove access as owner, or leave. These actions preserve shared debts and history. |
| **Notifications** | Save chore and money preferences. Push requires explicit opt-in on each account/device and a configured delivery service. |
| **Account lifecycle** | Delete the account with exact email confirmation, re-verification and recovery if deletion is pending. |

Owners with other active roommates must transfer ownership before leaving or deleting their account.
See the [native account guide](../Packages/RoomlingsCore/README.md) for permissions, failure handling and what deletion keeps.

## Data and availability

Sessions stay in the native Keychain. Minimal retention events go only to Roomlings, without message content or a third-party analytics SDK.
See the [privacy inventory](privacy.md).

Public app-opening invitations remain disabled until a domain and Apple association are configured.
Push delivery and TestFlight also need production services and signing; see [release setup](testflight.md).
