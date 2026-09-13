import { useSyncExternalStore } from 'react'
import { createRoot } from 'react-dom/client'
import { z } from 'zod'
import { KitchenPreview } from '@roomlings-web/src/KitchenWorld.tsx'
import { SceneLoading } from '@roomlings-web/src/Branding.tsx'
import { PreviewBoundary } from '@roomlings-web/src/landing/PreviewStatus.tsx'
import { roomStyleSchema } from '@roomlings-web/shared/domain.ts'
import { installRoomTouchControls } from './touchControls.ts'
import '@fontsource-variable/dm-sans/index.css'
import '@fontsource-variable/baloo-2/index.css'
import '@roomlings-web/src/style.css'
import '@roomlings-web/src/game.css'
import './viewport.css'

const stateSchema = z.object({
  version: z.literal(1),
  type: z.literal('state'),
  paused: z.boolean(),
  roomStyle: roomStyleSchema,
}).strict()

type RoomState = z.infer<typeof stateSchema>
type Status = 'loading' | 'ready' | 'unavailable'
type NativeMessage = { version: 1; type: 'status'; status: Status }

declare global {
  interface Window {
    RoomlingsRoom: { receive: (message: unknown) => { accepted: true } }
    webkit?: { messageHandlers?: { roomlings?: { postMessage: (message: NativeMessage) => void } } }
  }
}

let state: RoomState = { version: 1, type: 'state', paused: false, roomStyle: 'original' }
let status: Status = 'loading'
const listeners = new Set<() => void>()
const subscribe = (listener: () => void) => {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

Object.defineProperty(window, 'RoomlingsRoom', {
  value: Object.freeze({
    receive(message: unknown) {
      state = stateSchema.parse(message)
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

function Room() {
  const current = useSyncExternalStore(subscribe, () => state)
  const currentStatus = useSyncExternalStore(subscribe, () => status)
  return <main className="game-home native-room" aria-label="Roomlings kitchen preview">
    <PreviewBoundary onFailure={() => reportStatus('unavailable')}>
      <KitchenPreview roomStyle={current.roomStyle} paused={current.paused} onStatus={reportStatus} />
    </PreviewBoundary>
    {currentStatus === 'loading' && <SceneLoading label="Opening the kitchen..." />}
    {currentStatus === 'ready' && <span className="sr-only" role="status">Kitchen ready</span>}
  </main>
}

window.addEventListener('error', () => reportStatus('unavailable'))
window.addEventListener('unhandledrejection', () => reportStatus('unavailable'))
const root = document.getElementById('root')
if (!root) throw new Error('The bundled room is missing its mount point.')
installRoomTouchControls(document)
createRoot(root).render(<Room />)
