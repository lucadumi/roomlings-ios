# Native app privacy inventory

This inventory describes the implemented iOS data flows. It supports issue #11's release preparation; it is not the public privacy policy and does not submit App Store Connect answers.

`Roomlings/PrivacyInfo.xcprivacy` is included in the app target's resources. Xcode can use it when generating an archive's privacy report. It describes supported features, including optional push registration, even while the production services are not configured.

## Collected data

All declared data is linked to the account or its household membership. UUIDs and daily aggregation do not make it anonymous. There is no cross-app tracking, advertising use or declared tracking domain.

| Apple data category | Data in the native flow | Purpose |
| --- | --- | --- |
| Name | Account display name and roommate names used when creating or joining a household | App functionality |
| Email Address | Sign-in, recovery, re-verification and account-deletion confirmation | App functionality |
| Contacts | Household membership and roommate relationships, including the ownership handoff | App functionality |
| Other Financial Info | Household budget, expense amounts, payer/split references, debts and repayments | App functionality |
| Purchase History | Paid receipt records and completed shopping checkout history | App functionality |
| Other User Content | Household names, chore titles/notes, shopping item names/notes and member notification preferences | App functionality |
| User ID | Account/member/household identifiers and authenticated access; member attribution for retention events | App functionality and analytics |
| Device ID | Account-bound installation UUID and APNs device token for opted-in notifications | App functionality |
| Product Interaction | Account-session activity timestamps used for access expiry, plus app opens, successfully opened notifications, completed invitation sharing and confirmed invitation acceptance | App functionality and analytics |

The **Contacts** category covers the app's household relationships, not access to the phone's address book. Apple includes social graphs in this category. Roomlings does not request the Contacts permission.

The app records money but does not move it or collect card numbers or bank account details. **Other Financial Info** and **Purchase History** are therefore declared, not **Payment Info**.

Native receipts are text records, not uploaded photos. The room is a bundled 3D scene, not a scan of the user's surroundings. No camera, microphone, location, photo-library, advertising-identifier or tracking permission is added by this manifest.

## Implementation references

- [AccountAPI](../Packages/RoomlingsCore/Sources/RoomlingsCore/AccountAPI.swift) handles account identity, household creation/joining and deletion confirmation.
- [AccountModels](../Packages/RoomlingsCore/Sources/RoomlingsCore/AccountModels.swift) includes the server-maintained device/session activity and expiry timestamps.
- [HouseholdAccessAPI](../Packages/RoomlingsCore/Sources/RoomlingsCore/HouseholdAccessAPI.swift) sends member identifiers for ownership changes and reads the shared roster.
- [LedgerAPI](../Packages/RoomlingsCore/Sources/RoomlingsCore/LedgerAPI.swift) and [ShoppingAPI](../Packages/RoomlingsCore/Sources/RoomlingsCore/ShoppingAPI.swift) carry the shared financial and shopping records.
- [NotificationAPI](../Packages/RoomlingsCore/Sources/RoomlingsCore/NotificationAPI.swift) sends account-bound device registrations and member preferences.
- [AnalyticsModels](../Packages/RoomlingsCore/Sources/RoomlingsCore/AnalyticsModels.swift) and [AnalyticsAPI](../Packages/RoomlingsCore/Sources/RoomlingsCore/AnalyticsAPI.swift) restrict events to their kind, UTC timestamp and local date. Member attribution comes from the authenticated server request, not a free-text payload.
- [RoomWebView](../Roomlings/RoomWebView.swift) uses a nonpersistent web view for the bundled renderer. Account API calls and credentials remain native; the renderer receives only the allowlisted room state.

The native target links Apple's frameworks and the local `RoomlingsCore` package, which has no third-party package dependency. JavaScript room dependencies are bundled locally. There is no third-party analytics SDK. The Roomlings server uses its configured identity provider; the production provider, mail service and hosting logs still need to be included in the owner's release privacy review.

## Required-reason APIs

`NSPrivacyAccessedAPITypes` is empty because the shipping first-party Swift sources do not directly use the currently listed file-timestamp, system-boot-time, disk-space, active-keyboard-list or UserDefaults APIs. Native credentials and notification consent use Keychain rather than UserDefaults.

Build scripts and test tools reading file metadata are not shipped app code. Do not add a made-up required-reason code just to make an upload warning disappear. If the app or a future SDK adds a covered API, document the actual use and an applicable Apple-approved reason before shipping it. SDKs that require their own manifests must supply those manifests.

## Storage and deletion

The manifest is a disclosure, not a new collection mechanism. This change adds no requests, identifiers, tracking prompts or additional retention.

Native account credentials and account-bound notification consent stay in device-only Keychain entries. Event delivery has no disk queue, and invitation links remain in memory. Notification tokens are uploaded for opted-in registration rather than persisted by the app.

The server is authoritative for storage. Account deletion removes sign-in identity and access and pseudonymizes roster names, while shared financial history and references remain. In the currently pinned server, analytics aggregates expire 30 days after first receipt and are cleaned hourly; deleting an account is not a promise that every shared or retained row immediately disappears. See the [native deletion guide](../Packages/RoomlingsCore/README.md#account-deletion) and the server's [storage guide](https://github.com/lucadumi/roomlings/blob/b06cd70/docs/storage.md).

## Before distribution

Review this inventory whenever native payloads, server data use, logging, retention, SDKs or the pinned renderer change. The bundle checks detect missing or changed declarations; they are not an automated privacy audit.

Once a valid signed archive is available, use **Organizer > Generate Privacy Report** and compare it with this inventory and the deployed services. The owner must still publish a real privacy policy, confirm provider and backup practices, and enter the matching privacy answers in App Store Connect. Do not choose “Data Not Collected.”

Apple references:

- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Describing data use](https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests)
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [App privacy details and category definitions](https://developer.apple.com/app-store/app-privacy-details/)
