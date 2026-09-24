import { mkdir, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { isPublicHTTPSOrigin } from './check-release.mjs'

export function invitationAssociation(settings) {
  const enabled = settings.ROOMLINGS_UNIVERSAL_LINKS ?? 'NO'
  if (!['YES', 'NO'].includes(enabled)) {
    throw new Error('Set ROOMLINGS_UNIVERSAL_LINKS to YES or NO. See docs/invitations.md.')
  }
  const entitlements = enabled === 'YES' ? 'Roomlings/RoomlingsLinks.entitlements' : 'Roomlings/Roomlings.entitlements'
  if (settings.PLATFORM_NAME === 'iphoneos' && settings.CODE_SIGN_ENTITLEMENTS !== entitlements) {
    throw new Error('Use the shared CODE_SIGN_ENTITLEMENTS selection for ROOMLINGS_UNIVERSAL_LINKS. See docs/invitations.md.')
  }
  if (enabled === 'NO') return null

  const failures = []
  if (!isPublicHTTPSOrigin(settings.ROOMLINGS_INVITATION_SCHEME, settings.ROOMLINGS_INVITATION_HOST)
      || settings.ROOMLINGS_INVITATION_HOST.includes(':')) {
    failures.push('Set ROOMLINGS_INVITATION_SCHEME=https and ROOMLINGS_INVITATION_HOST to the approved public domain, without a port, path or credentials.')
  }
  if (!/^[A-Z0-9]{10}$/.test(settings.ROOMLINGS_APP_ID_PREFIX ?? '')) {
    failures.push('Set ROOMLINGS_APP_ID_PREFIX to the signed app\'s actual ten-character App ID prefix. Do not assume it is the team identifier.')
  }
  if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(settings.PRODUCT_BUNDLE_IDENTIFIER ?? '')) {
    failures.push('Set PRODUCT_BUNDLE_IDENTIFIER to the explicit registered app identifier.')
  }
  if (failures.length) {
    throw new Error(`Cannot enable invitation Universal Links:\n${failures.map((failure) => `- ${failure}`).join('\n')}\nSee docs/invitations.md.`)
  }
  return {
    applinks: {
      details: [{
        appIDs: [`${settings.ROOMLINGS_APP_ID_PREFIX}.${settings.PRODUCT_BUNDLE_IDENTIFIER}`],
        components: [{ '/': '/', '?': '', '#': `account-invite=roomlings-invite-${'?'.repeat(43)}` }],
      }],
    },
  }
}

export async function writeInvitationAssociation(association, directory) {
  const output = join(directory, 'apple-app-site-association')
  if (association === null) {
    await rm(output, { force: true })
    return
  }
  await mkdir(directory, { recursive: true })
  await writeFile(output, JSON.stringify(association, null, 2) + '\n')
}
