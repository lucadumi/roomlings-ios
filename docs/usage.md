# Using Roomlings

## Household and room

Sign in or recover access, then create or join a household to open its saved kitchen.
**Rooms** in the header switches between the shared kitchen, bathroom and living room.
The room adapts to either orientation. Zoom includes object focus; **Reset room view** returns to 100%.

| Control | What it does |
| --- | --- |
| **Chores** or an object's **+** marker | View, add, edit, complete and undo tasks with shared schedules and rotations. Chores open on the room you are viewing. |
| **Shopping** | Add, edit, claim and pick up items. Record a paid receipt to split its cost in the shared ledger. Picking up an item alone creates no debt. |
| **Money** | View receipts, balances and repayments. **Bills** schedules monthly bills and records or undoes their payments. **Export ledger** shares the complete ledger as the same CSV file the web exports. Roomlings tracks money; it never moves it. |
| Bell beside **Rooms** | Your chore turns that are due or overdue, plus expenses, bills and repayments from the last 30 days that involve you. Select one to open it; **Mark all read** clears the count. Read state is yours alone and follows you across devices. |
| Box beside the bell | The objects in this room. Select one to set its manual state, review its supply shortcuts and add them to the shopping list, or open, add and choose suggested chores. Owners and room admins use **Edit room** to add, move, customise and store objects. |
| Household name or avatar | Open **Account**. |

**Edit room** keeps a private draft. Previewing an object steps the sheet aside to show it in the live room; a blocked position offers a swap into Storage.
Nothing reaches roommates until **Apply for everyone**. Stored objects pause their linked chores and keep their history.
Use the pencil or archive action beside **Mark done** to manage a chore.
**Archived** restores saved schedules; **History > Schedule again** reschedules a completed one-off without changing its completion history.
Stored-object chores must wait for their object to return before editing or restoring. Archiving keeps history and does not free a chore slot.
An object gets dirty when one of its chores is overdue: light crumbs after 1 day, more mess after 3 and filthy after 7. Completing the chore cleans it at once. Area markers show how many chores are due.

## Account

| Section | What it does |
| --- | --- |
| **Edit profile**, **Account sessions** | Rename your account or this device, sign out another device, or sign out everywhere. |
| **Recovery codes** | Generate, replace or revoke ten single-use codes. New codes are shown once; copying keeps them on this device for two minutes. |
| **House rules** | Any roommate can change the household name, monthly grocery budget and currency. Currency stays fixed after expenses, repayments or monthly bills. |
| **Room style** | Owners and room admins apply one shared look to the room for everyone. Other roommates can browse the styles. |
| Invitations | Owners share seven-day invitations and revoke pending links. See [invitation setup](invitations.md). |
| **Membership** | From the open household in **Your households**, see your roommates and their grocery runs, invite someone as owner, transfer ownership, remove access as owner, or leave. These actions preserve shared debts and history. |
| **Household admins** | Owners and admins grant or remove room admin rights. |
| **Notifications** | Save chore and money preferences. Push requires explicit opt-in on each account/device and a configured delivery service. |
| **Account lifecycle** | Delete the account with exact email confirmation, re-verification and recovery if deletion is pending. |

Owners with other active roommates must transfer ownership before leaving or deleting their account.
See the [native account guide](../Packages/RoomlingsCore/README.md) for permissions, failure handling and what deletion keeps.

## Data and availability

Sessions stay in the native Keychain. Minimal retention events go only to Roomlings, without message content or a third-party analytics SDK.
See the [privacy inventory](privacy.md).

Public app-opening invitations remain disabled until a domain and Apple association are configured.
Push delivery and TestFlight also need production services and signing; see [release setup](testflight.md).
