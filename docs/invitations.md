# Invitation links

## Current behavior

Owners create, share and revoke invitations in **Account**. Local links can be pasted into **Join a household**.
The default `http://localhost:5173` origin works on the same Mac and its simulators, not another physical device.

**Universal Links are disabled by default. No public domain has been chosen.**
Preparing the app's configuration does not deploy a website, configure Apple provisioning or satisfy issue #8's real-device acceptance.

The approved not-installed flow is web-first: open the invitation in the browser, join there, then install Roomlings and sign into the same account.
The membership is restored from the server. There is no deferred-link provider, clipboard scanning or install tracking.

## Enable after choosing a domain

Use `Configuration/Local.xcconfig` for Debug or `Configuration/Release.local.xcconfig` for Release.
Keep these settings disabled or blank until the actual website and signing identity are agreed:

```xcconfig
ROOMLINGS_UNIVERSAL_LINKS = NO
ROOMLINGS_APP_ID_PREFIX =
```

Once approved:

1. Serve the existing web app at the chosen public HTTPS origin. Set `ROOMLINGS_INVITATION_SCHEME=https` and `ROOMLINGS_INVITATION_HOST` to its exact domain. Do not include a port, path, wildcard or `applinks:` prefix. The API may use a different origin.
2. Set `ROOMLINGS_APP_ID_PREFIX` to the signed app's ten-character App ID prefix, without a trailing dot. Verify it against the `application-identifier` entitlement; it is not necessarily `DEVELOPMENT_TEAM`. Keep `PRODUCT_BUNDLE_IDENTIFIER` aligned with the registered app.
3. Set `ROOMLINGS_UNIVERSAL_LINKS=YES` and enable Associated Domains for that App ID and its provisioning profile. The shared configuration selects `RoomlingsLinks.entitlements` for device builds. Do not override `CODE_SIGN_ENTITLEMENTS`.
4. Build the app. The room build writes `Build/InvitationLinks/apple-app-site-association` outside the app bundle. Host that generated JSON at `https://<chosen-domain>/.well-known/apple-app-site-association`, without authentication or redirects.
5. Verify the signed app's `application-identifier` matches the generated `appIDs` entry, and its associated domain matches the website. Test links from Messages on a physical device after Apple's association is available.

The build rejects incomplete opt-in settings before loading the web source. Local/reserved hosts, custom ports and missing prefixes cannot enable links.
It cannot verify DNS ownership, TLS, provisioning or Apple's cached association.

Setting the flag back to `NO` restores the original push-only entitlement file and removes the generated association artifact on the next successful build.
It does not unpublish a previously hosted file or change apps already installed.

## Routing and privacy

The association matches only the root path, an empty query and the `account-invite=roomlings-invite-` fragment with a 43-character code.
The existing native `onOpenURL` handler checks the configured origin, root path, absence of a query and the complete fragment before presenting the invitation.
Authentication and explicit confirmation are still required; opening a link never joins automatically.

Codes remain case-sensitive. Invalid links show a generic error without sending the URL to the API or renderer.
Explicitly pasting a link or code still parses it locally and never navigates to its host.
See the [native invitation contract](../Packages/RoomlingsCore/README.md#invitations).

## Verification before enabling

The [development guide](development.md#targeted-native-flows) lists the isolated invitation flows.
They cover signed-out and restored launches, revoked links, web-first membership restoration and preservation of browser sessions.
They do not prove Apple's domain association.

Before closing #8, verify Messages links with the app installed, a revoked invitation, and the web-first journey with the app initially absent.
Check that ordinary account and recovery links still stay on the website.
Follow Apple's [Associated Domains setup](https://developer.apple.com/documentation/xcode/supporting-associated-domains) and [association format](https://developer.apple.com/documentation/bundleresources/applinks).
