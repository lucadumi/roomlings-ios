import { useLayoutEffect, useRef, useState, useSyncExternalStore } from 'react'
import type { CSSProperties } from 'react'
import { createRoot } from 'react-dom/client'
import { ListChecks, ShoppingBasket } from 'lucide-react'
import { z } from 'zod'
import { KitchenPreview } from '@roomlings-web/src/KitchenWorld.tsx'
import { SceneLoading } from '@roomlings-web/src/Branding.tsx'
import { PreviewBoundary } from '@roomlings-web/src/landing/PreviewStatus.tsx'
import { roomStyleSchema } from '@roomlings-web/shared/domain.ts'
import { getRoomComponents, roomComponentLimit, roomComponentSchema } from '@roomlings-web/shared/roomComponents.ts'
import { installRoomTouchControls } from './touchControls.ts'
import '@fontsource-variable/dm-sans/index.css'
import '@fontsource-variable/baloo-2/index.css'
import '@roomlings-web/src/style.css'
import '@roomlings-web/src/game.css'
import './viewport.css'

const inset = z.number().nonnegative().max(4096)
const stateSchema = z.object({
  version: z.literal(1),
  type: z.literal('state'),
  paused: z.boolean(),
  roomStyle: roomStyleSchema,
  roomZoom: z.number().min(1).max(1.5).default(1),
  householdId: z.string().uuid().nullable().default(null),
  choresEnabled: z.boolean().default(false),
  shoppingEnabled: z.boolean().default(false),
  roomComponents: z.array(roomComponentSchema).max(roomComponentLimit).optional(),
  viewportInsets: z.object({ top: inset, right: inset, bottom: inset, left: inset }).strict()
    .default({ top: 0, right: 0, bottom: 0, left: 0 }),
}).strict().refine((value) => (!value.choresEnabled && !value.shoppingEnabled) || value.householdId !== null, {
  message: 'Household tools require a selected household.',
  path: ['householdId'],
})

type RoomState = z.infer<typeof stateSchema>
type Status = 'loading' | 'ready' | 'unavailable'
type NativeMessage = { version: 1; type: 'status'; status: Status }
  | { version: 1; type: 'open-chores'; householdId: string; componentId?: string }
  | { version: 1; type: 'open-shopping'; householdId: string }

declare global {
  interface Window {
    RoomlingsRoom: { receive: (message: unknown) => { accepted: true } }
    webkit?: { messageHandlers?: { roomlings?: { postMessage: (message: NativeMessage) => void } } }
  }
}

let state: RoomState = stateSchema.parse({ version: 1, type: 'state', paused: false, roomStyle: 'original' })
let status: Status = 'loading'
const listeners = new Set<() => void>()
const subscribe = (listener: () => void) => {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

Object.defineProperty(window, 'RoomlingsRoom', {
  value: Object.freeze({
    receive(message: unknown) {
      const next = stateSchema.parse(message)
      if (next.householdId !== state.householdId) {
        status = 'loading'
        document.documentElement.dataset.roomStatus = 'loading'
      }
      state = next
      for (const listener of listeners) listener()
      return { accepted: true as const }
    },
  }),
  writable: false,
  configurable: false,
})

function reportStatus(next: Status) {
  status = next
  document.documentElement.dataset.roomStatus = next
  window.webkit?.messageHandlers?.roomlings?.postMessage({ version: 1, type: 'status', status: next })
  for (const listener of listeners) listener()
}

function openChores(componentId?: string) {
  if (state.choresEnabled && state.householdId && !state.paused && status === 'ready') {
    window.webkit?.messageHandlers?.roomlings?.postMessage({
      version: 1, type: 'open-chores', householdId: state.householdId,
      ...(componentId === undefined ? {} : { componentId }),
    })
  }
}

function openShopping() {
  if (state.shoppingEnabled && state.householdId && !state.paused && status === 'ready') {
    window.webkit?.messageHandlers?.roomlings?.postMessage({
      version: 1, type: 'open-shopping', householdId: state.householdId,
    })
  }
}

function Room() {
  const current = useSyncExternalStore(subscribe, () => state)
  const currentStatus = useSyncExternalStore(subscribe, () => status)
  const dock = useRef<HTMLElement>(null)
  const [dockSpace, setDockSpace] = useState(0)
  const hasChores = current.choresEnabled && current.householdId !== null
  const hasShopping = current.shoppingEnabled && current.householdId !== null
  const hasTools = hasChores || hasShopping
  useLayoutEffect(() => {
    const element = dock.current
    if (!element) { setDockSpace(0); return }
    const measure = () => setDockSpace(element.getBoundingClientRect().height + 32)
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    measure()
    return () => observer.disconnect()
  }, [hasTools])
  const viewportStyle: CSSProperties & Record<`--native-${'top' | 'right' | 'bottom' | 'left' | 'dock-space'}`, string> = {
    '--native-top': `${current.viewportInsets.top}px`,
    '--native-right': `${current.viewportInsets.right}px`,
    '--native-bottom': `${current.viewportInsets.bottom}px`,
    '--native-left': `${current.viewportInsets.left}px`,
    '--native-dock-space': `${hasTools ? dockSpace : 0}px`,
  }
  return <main className="game-home native-room" aria-label={current.householdId ? 'Shared household kitchen' : 'Roomlings kitchen preview'}
    data-household-id={current.householdId ?? ''} style={viewportStyle}>
    <PreviewBoundary key={current.householdId ?? 'preview'} onFailure={() => reportStatus('unavailable')}>
      <KitchenPreview roomStyle={current.roomStyle} roomZoom={current.roomZoom} paused={current.paused} onStatus={reportStatus}
        onComponentSelect={hasChores ? openChores : undefined}
        components={getRoomComponents({ roomComponents: current.roomComponents })} />
    </PreviewBoundary>
    {currentStatus === 'loading' && <SceneLoading label="Opening the kitchen..." />}
    {currentStatus === 'ready' && <span className="sr-only" role="status">Kitchen ready</span>}
    {hasTools && <nav className="game-dock native-tools-dock" aria-label="Household tools" ref={dock}>
      {hasChores && <button type="button" className="dock-tool" data-tool="chores" aria-label="Chores" title="Chores"
        aria-haspopup="dialog" disabled={current.paused || currentStatus !== 'ready'} onClick={() => openChores()}>
        <ListChecks size="1.3125rem" /><span>Chores</span>
      </button>}
      {hasShopping && <button type="button" className="dock-tool" data-tool="stock" aria-label="Shopping" title="Shopping"
        aria-haspopup="dialog" disabled={current.paused || currentStatus !== 'ready'} onClick={openShopping}>
        <ShoppingBasket size="1.3125rem" /><span>Shopping</span>
      </button>}
    </nav>}
  </main>
}

window.addEventListener('error', () => reportStatus('unavailable'))
window.addEventListener('unhandledrejection', () => reportStatus('unavailable'))
const root = document.getElementById('root')
if (!root) throw new Error('The bundled room is missing its mount point.')
installRoomTouchControls(document)
createRoot(root).render(<Room />)
