import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import type { ComponentType, CSSProperties } from 'react'
import { createRoot } from 'react-dom/client'
import { ListChecks, ShoppingBasket, Wallet } from 'lucide-react'
import { z } from 'zod'
import { KitchenPreview } from '@roomlings-web/src/KitchenWorld.tsx'
import type { KitchenPreviewProps } from '@roomlings-web/src/KitchenWorld.tsx'
import { SceneLoading } from '@roomlings-web/src/Branding.tsx'
import { PreviewBoundary } from '@roomlings-web/src/landing/PreviewStatus.tsx'
import { billingDate, dateSchema, roomStyleSchema, timeZoneSchema } from '@roomlings-web/shared/domain.ts'
import { choreStatus, componentGrime } from '@roomlings-web/shared/chores.ts'
import type { ChoreGrime } from '@roomlings-web/shared/chores.ts'
import type { Chore } from '@roomlings-web/shared/domain.ts'
import type { ChoreArea } from '@roomlings-web/shared/rooms.ts'
import { choreAreaSchema, roomCatalog, roomIdSchema } from '@roomlings-web/shared/rooms.ts'
import {
  componentCatalog, componentChoreIsPaused, componentFinishSchema, componentKindSchema, getRoomComponents, roomComponentIdSchema,
  roomComponentLimit, roomComponentSchema, roomSlotIdSchema,
} from '@roomlings-web/shared/roomComponents.ts'
import { renderComponentThumbnail } from '@roomlings-web/src/componentThumbnail.ts'
import { installRoomTouchControls } from './touchControls.ts'
import { ScaledChoreRoom, choreRooms } from './choreRooms.tsx'
import '@fontsource-variable/dm-sans/index.css'
import '@fontsource-variable/baloo-2/index.css'
import '@roomlings-web/src/style.css'
import '@roomlings-web/src/game.css'
import './viewport.css'

const inset = z.number().nonnegative().max(4096)
// Only where and when each chore is due: no titles, notes or roommates reach the web view.
const choreCareSchema = z.object({
  roomId: roomIdSchema.nullable(),
  area: choreAreaSchema.nullable(),
  componentId: roomComponentIdSchema.nullable().optional(),
  dueDate: dateSchema.nullable(),
  archived: z.boolean(),
}).strict()
const stateSchema = z.object({
  version: z.literal(1),
  type: z.literal('state'),
  paused: z.boolean(),
  roomStyle: roomStyleSchema,
  roomId: roomIdSchema.default('kitchen'),
  roomZoom: z.number().min(0.3).max(1.5).default(1),
  householdId: z.string().uuid().nullable().default(null),
  choresEnabled: z.boolean().default(false),
  shoppingEnabled: z.boolean().default(false),
  moneyEnabled: z.boolean().default(false),
  roomComponents: z.array(roomComponentSchema).max(roomComponentLimit).optional(),
  // The household's chore schedule and calendar, so overdue care dirties objects as on the web.
  billingTimeZone: timeZoneSchema.default('UTC'),
  chores: z.array(choreCareSchema).max(200).default([]),
  viewportInsets: z.object({ top: inset, right: inset, bottom: inset, left: inset }).strict()
    .default({ top: 0, right: 0, bottom: 0, left: 0 }),
}).strict().refine((value) => (!value.choresEnabled && !value.shoppingEnabled && !value.moneyEnabled)
  || value.householdId !== null, {
  message: 'Household tools require a selected household.',
  path: ['householdId'],
}).refine((value) => value.roomId === 'kitchen' || (value.choresEnabled && value.shoppingEnabled), {
  // Their chore and supply markers always show, so these rooms need working household tools.
  message: 'The bathroom and living room require chores and shopping.',
  path: ['roomId'],
})

type RoomState = z.infer<typeof stateSchema>
// The kitchen preview forwards every prop to the kitchen, which draws overdue dirt. The renderer
// test checks that each dirty object's marker reports its level.
const Kitchen = KitchenPreview as ComponentType<KitchenPreviewProps & { grime: Readonly<Record<string, ChoreGrime>> }>

// Today's date in the household calendar, refreshed so dirt grows past midnight without a reload.
function useBillingDate(timeZone: string) {
  const [today, setToday] = useState(() => billingDate(timeZone))
  useEffect(() => {
    const refresh = () => setToday(billingDate(timeZone))
    refresh()
    const timer = window.setInterval(refresh, 60_000)
    return () => window.clearInterval(timer)
  }, [timeZone])
  return today
}
type Status = 'loading' | 'ready' | 'unavailable'
type NativeMessage = { version: 1; type: 'status'; status: Status }
  | { version: 1; type: 'open-chores'; householdId: string; componentId?: string }
  | { version: 1; type: 'open-shopping'; householdId: string }
  | { version: 1; type: 'open-money'; householdId: string }

declare global {
  interface Window {
    RoomlingsRoom: {
      receive: (message: unknown) => { accepted: true }
      thumbnail: (request: unknown) => Promise<string>
    }
    webkit?: { messageHandlers?: { roomlings?: { postMessage: (message: NativeMessage) => void } } }
  }
}

const thumbnailSchema = z.object({
  version: z.literal(1), roomId: roomIdSchema, kind: componentKindSchema, slotId: roomSlotIdSchema,
  variant: z.string().min(1).max(40), finish: componentFinishSchema, state: z.string().min(1).max(40).nullable(),
  roomStyle: roomStyleSchema,
}).strict()

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
      if (next.householdId !== state.householdId || next.roomId !== state.roomId) {
        status = 'loading'
        document.documentElement.dataset.roomStatus = 'loading'
      }
      state = next
      for (const listener of listeners) listener()
      return { accepted: true as const }
    },
    // The web's object card picture for the native objects sheet. It needs only how the object looks.
    thumbnail(request: unknown) {
      const { roomId, kind, slotId, variant, finish, state, roomStyle } = thumbnailSchema.parse(request)
      const component = roomComponentSchema.parse({
        id: 'thumbnail', kind, roomId, slotId, name: componentCatalog[kind].name, variant, finish, supplies: [],
        installed: true, version: 0, state, stateChangedAt: null, stateChangedBy: null,
      })
      return renderComponentThumbnail(component, roomStyle)
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

function openMoney() {
  if (state.moneyEnabled && state.householdId && !state.paused && status === 'ready') {
    window.webkit?.messageHandlers?.roomlings?.postMessage({
      version: 1, type: 'open-money', householdId: state.householdId,
    })
  }
}

function Room() {
  const current = useSyncExternalStore(subscribe, () => state)
  const currentStatus = useSyncExternalStore(subscribe, () => status)
  const viewport = useRef<HTMLElement>(null)
  const dock = useRef<HTMLElement>(null)
  const [landscape, setLandscape] = useState(false)
  const [dockSpace, setDockSpace] = useState(0)
  const [dockWidth, setDockWidth] = useState(0)
  const [dockHeight, setDockHeight] = useState(0)
  const hasChores = current.choresEnabled && current.householdId !== null
  const hasShopping = current.shoppingEnabled && current.householdId !== null
  const hasMoney = current.moneyEnabled && current.householdId !== null
  const hasTools = hasChores || hasShopping || hasMoney
  useLayoutEffect(() => {
    const element = viewport.current
    if (!element) return
    const measure = () => setLandscape(element.clientWidth > element.clientHeight)
    const observer = new ResizeObserver(measure)
    observer.observe(element)
    measure()
    return () => observer.disconnect()
  }, [])
  useLayoutEffect(() => {
    const tools = dock.current
    const actions = viewport.current?.querySelector('.world-quick-actions')
    const measure = () => {
      const bounds = tools?.getBoundingClientRect()
      const actionHeight = landscape ? actions?.getBoundingClientRect().height ?? 0 : 0
      setDockSpace(hasTools || landscape ? Math.max(bounds?.height ?? 0, actionHeight) + 32 : 0)
      setDockWidth(bounds?.width ?? 0)
      setDockHeight(bounds?.height ?? 0)
    }
    const observer = new ResizeObserver(measure)
    if (tools) observer.observe(tools)
    if (actions) observer.observe(actions)
    measure()
    return () => observer.disconnect()
  }, [hasTools, landscape, currentStatus])
  const viewportStyle: CSSProperties & Record<`--native-${'top' | 'right' | 'bottom' | 'left' | 'dock-space' | 'dock-width' | 'dock-height'}`, string> = {
    '--native-top': `${current.viewportInsets.top}px`,
    '--native-right': `${current.viewportInsets.right}px`,
    '--native-bottom': `${current.viewportInsets.bottom}px`,
    '--native-left': `${current.viewportInsets.left}px`,
    '--native-dock-space': `${dockSpace}px`,
    '--native-dock-width': `${hasTools ? dockWidth : 0}px`,
    '--native-dock-height': `${hasTools ? dockHeight : 0}px`,
  }
  const room = roomCatalog[current.roomId]
  const components = useMemo(() => getRoomComponents({ roomComponents: current.roomComponents }), [current.roomComponents])
  const today = useBillingDate(current.billingTimeZone)
  // The shared rules read only the schedule fields that the native app sends.
  const chores = current.chores as unknown as readonly Chore[]
  const grime = useMemo(() => componentGrime(chores, components, today), [chores, components, today])
  const dueChores = useMemo(() => {
    const due: Partial<Record<ChoreArea, number>> = {}
    for (const chore of chores) {
      if (chore.roomId !== current.roomId || !chore.area || componentChoreIsPaused(chore, components)
        || !['due', 'overdue'].includes(choreStatus(chore, today))) continue
      due[chore.area] = (due[chore.area] ?? 0) + 1
    }
    return due
  }, [chores, current.roomId, components, today])
  const choreRoom = current.roomId === 'kitchen' ? null : choreRooms[current.roomId]
  return <main ref={viewport} className="game-home native-room"
    aria-label={current.householdId ? `Shared household ${room.name.toLowerCase()}` : 'Roomlings kitchen preview'}
    data-household-id={current.householdId ?? ''} data-room-id={current.roomId} data-landscape={landscape} data-has-tools={hasTools} style={viewportStyle}>
    <PreviewBoundary key={`${current.householdId ?? 'preview'}-${current.roomId}`} onFailure={() => reportStatus('unavailable')}>
      {choreRoom
        ? <ScaledChoreRoom room={choreRoom} roomZoom={current.roomZoom} roomStyle={current.roomStyle} paused={current.paused} panelOpen={false} onStatus={reportStatus}
          focusRequest={{ target: 'room', id: 0 }} dueChores={dueChores} grime={grime} components={components}
          onOpenChores={() => openChores()} onRestock={openShopping}
          onComponentSelect={hasChores ? openChores : undefined} />
        : <Kitchen grime={grime} roomStyle={current.roomStyle} roomZoom={current.roomZoom} paused={current.paused} onStatus={reportStatus}
          wholeRoomView={false} cameraToolsInQuickActions={landscape}
          onComponentSelect={hasChores ? openChores : undefined} components={components} />}
    </PreviewBoundary>
    {currentStatus === 'loading' && <SceneLoading label={`Opening the ${room.name.toLowerCase()}...`} />}
    {currentStatus === 'ready' && <span className="sr-only" role="status">{`${room.name} ready`}</span>}
    {hasTools && <nav className="game-dock native-tools-dock" aria-label="Household tools" ref={dock}>
      {hasChores && <button type="button" className="dock-tool" data-tool="chores" aria-label="Chores" title="Chores"
        aria-haspopup="dialog" disabled={current.paused || currentStatus !== 'ready'} onClick={() => openChores()}>
        <ListChecks size="1.3125rem" /><span>Chores</span>
      </button>}
      {hasShopping && <button type="button" className="dock-tool" data-tool="stock" aria-label="Shopping" title="Shopping"
        aria-haspopup="dialog" disabled={current.paused || currentStatus !== 'ready'} onClick={openShopping}>
        <ShoppingBasket size="1.3125rem" /><span>Shopping</span>
      </button>}
      {hasMoney && <button type="button" className="dock-tool" data-tool="money" aria-label="Money" title="Money"
        aria-haspopup="dialog" disabled={current.paused || currentStatus !== 'ready'} onClick={openMoney}>
        <Wallet size="1.3125rem" /><span>Money</span>
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
