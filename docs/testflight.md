# Preparing a TestFlight build

Issue #11 remains open until another person installs the app from TestFlight and joins a household. A successful unsigned build or archive configuration check is not a shipped beta.

## Release configuration

Debug continues to use the ignored `Configuration/Local.xcconfig`. Release uses the separate ignored `Configuration/Release.local.xcconfig`, so a local API override cannot silently enter a distribution build.

If the release override file does not already exist:

```sh
cp -n Configuration/Release.local.xcconfig.example Configuration/Release.local.xcconfig
```

Fill in the approved Apple Developer team and public HTTPS API/invitation hosts. Hosts contain only an ASCII domain and optional numeric port, not a scheme, path, query or credentials. Use punycode for internationalized domains. Keep certificates and private keys in Xcode/Keychain. Set any machine-specific `NODE_BINARY` and `ROOMLINGS_WEB_ROOT` paths in the release file too; Debug overrides are deliberately not inherited.

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` now populate `CFBundleShortVersionString` and `CFBundleVersion`. Their existing defaults remain `0.1.0` and `1`. Agree the release version with the owner and increment the build number for every upload. The app target no longer overrides these values.

## Native icon and launch artwork

The approved treatment uses the existing four-colour Roomlings mark on an opaque white app-icon canvas, plus a small centred mark on a white launch screen. The launch storyboard keeps the image at 64 points in either orientation on iPhone and iPad. It adds no text, animation, controls or custom icon mask.

The PNGs in `Roomlings/Resources/Assets.xcassets` are derived platform resources, not separately editable branding. `Scripts/build-brand-assets.mjs` renders the shared `src/assets/brand/roomlings-icon-flat.svg` using the web project's existing Playwright tooling. The icon is 1024 by 1024 RGB with no alpha channel; the launch mark has transparent 1x, 2x and 3x variants. Web favicons are unchanged.

`Roomlings/Resources/BrandAssets.json` records the vector source hash, generation revision, approved background and image hashes. Every room build checks those against the selected web source and fails if the artwork is stale or altered. The paper colour must still be the approved white. Ordinary Xcode builds only check the assets; they do not launch a browser or regenerate them.

After an approved branding change, use a compatible web checkout with its locked dependencies and Playwright browser available:

```sh
ROOMLINGS_WEB_ROOT=/path/to/roomlings node Scripts/build-brand-assets.mjs --write
ROOMLINGS_WEB_ROOT=/path/to/roomlings node --test Tests/Branding/brand-assets.test.mjs
```

Review the generated images and provenance together. Do not edit the output PNGs by hand or enlarge the small loader image.

## Archive safeguards

The existing room-bundling build phase checks every Xcode archive/install action before generating resources. It requires:

- Release for a physical iOS device, enabled signing, a team identifier and an explicit bundle identifier.
- Public HTTPS API and invitation origins. Missing hosts, loopback/IP addresses, local names, reserved example domains and URLs containing credentials are rejected.
- Numeric version/build metadata, production APNs, and no `DEBUG` compilation or testability.
- A clean web checkout at the full revision pinned in `.github/workflows/ci.yml`. Untracked web source files also count as changes; ignored dependencies, data and configuration do not.

Use an isolated web checkout for distribution. Do not switch the shared review server's checkout or migrate its database just to build an archive.

These checks do not contact Apple or the configured hosts. They cannot establish team membership, valid provisioning, TLS reachability, backend schema compatibility or App Review approval. `APIConfiguration` still enforces HTTPS for non-loopback runtime requests.

Ordinary Debug and unsigned Release **builds** remain possible without production configuration. CI deliberately compiles an unsigned device Release using reserved test hosts, then checks the built app's version, endpoints and APNs metadata. Such a build is not distributable, and an **archive** with those settings fails.

```sh
node --test Tests/Release/release.test.mjs
```

## Prerequisites before upload

| Prerequisite | Current state or required action |
| --- | --- |
| Developer membership and signing | Configure the owner's team, App Store Connect record and matching push-enabled provisioning for the approved bundle identifier. The current identifier is `com.roomlings.app`; it is not proof that it is registered. |
| Production services | Select and deploy the public HTTPS API and invitation website. The current client expects the server's schema-5-compatible features. Deployment and any shared database migration require separate approval and a recovery plan. |
| Icon, launch presentation and version | The approved icon and centred launch mark are packaged from the shared vector artwork. Review the appearance on a real device and agree the release version/build number before uploading. |
| Account deletion | The native [Account lifecycle flow](../Packages/RoomlingsCore/README.md#account-deletion) provides confirmation, re-verification and pending-deletion recovery. Owners with other active roommates can first transfer ownership in **Account > Household members**. Verify the deployed provider and recovery path before review. |
| Privacy | The app bundles `PrivacyInfo.xcprivacy` with its current first-party data declarations. Review the [data inventory](privacy.md), generate the signed archive's privacy report, publish the privacy policy and enter matching App Store privacy answers for the deployed services. Do not declare that no data is collected. |
| Review information | Provide a beta description, test instructions, working sign-in access and review contact details through App Store Connect. |
| Cohort | The owner still needs to choose a private tester list or an external public link. External access requires Beta App Review. Do not enable the marketing site's TestFlight link before that access exists. |

Universal Links have [opt-in configuration](invitations.md), but remain disabled until a public domain, hosted association file and matching provisioning are ready. An HTTPS invitation origin alone does not enable app-opening links. Until then, use share/copy and paste-to-join. Without the app, the approved flow is to join on the website and later sign into the same native account.

## Archive and distribute

After the prerequisites and release settings are ready, select **Any iOS Device** and **Product > Archive** in Xcode, or run the equivalent command. Use a new archive path for each build; this example uses build `1`.

```sh
xcodebuild -project Roomlings.xcodeproj -scheme Roomlings \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath Build/Roomlings-1.xcarchive \
  NODE_BINARY="$(command -v node)" archive
```

Inspect the archived app's `Info.plist`, `PrivacyInfo.xcprivacy` and `RoomRenderer/source.json`, then use Organizer to generate the privacy report, validate and upload the approved archive. No repository script uploads a build or changes Apple credentials.

Follow [Apple's upload instructions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) and current [upload requirements](https://developer.apple.com/news/upcoming-requirements/). Once processing and review finish, verify on real devices that a tester can sign in, join a household and use its chores, shopping and money. Keep #9 open until a real due-chore push arrives and #10 open until a real week's retention events can be reported.
