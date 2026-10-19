import { useEffect, useMemo, useRef, useState } from 'react'
import type { ReactElement } from 'react'
import ChoreRoomWorld from '@roomlings-web/src/ChoreRoomWorld.tsx'
import type { ChoreRoomConfig, ChoreRoomWorldProps } from '@roomlings-web/src/ChoreRoomWorld.tsx'
import BathroomWorld from '@roomlings-web/src/BathroomWorld.tsx'
import LivingRoomWorld from '@roomlings-web/src/LivingRoomWorld.tsx'
import { roomCameraZoom } from '@roomlings-web/src/camera.ts'
import { installedRoomComponents } from '@roomlings-web/src/roomComponentScene.ts'

export const choreRooms = { bathroom: BathroomWorld, 'living-room': LivingRoomWorld }
type SharedRoom = typeof choreRooms[keyof typeof choreRooms]
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- each shared room has its own target union.
type AnyConfig = ChoreRoomConfig<any>

// Each shared room is a thin wrapper that renders ChoreRoomWorld with its own configuration.
// Reading that element keeps the scene, labels and copy in the web project instead of copying them.
function sharedConfig(room: SharedRoom): AnyConfig {
  const element = (room as (props: never) => ReactElement<{ config?: AnyConfig }>)({} as never)
  if (element?.type !== ChoreRoomWorld || !element.props.config) {
    throw new Error('The shared room no longer renders a chore room configuration.')
  }
  return element.props.config
}

/** A shared bathroom or living room entered at the kitchen's native scale, like `KitchenPreview` with `roomZoom`. */
export function ScaledChoreRoom({ room, roomZoom, onComponentSelect, ...props }: { room: SharedRoom; roomZoom: number }
  & ChoreRoomWorldProps<string>) {
  // The scene reads its configuration once, so the camera reads the latest scale from a ref.
  const scale = useRef(roomZoom)
  scale.current = roomZoom
  const config = useMemo<AnyConfig>(() => {
    const shared = sharedConfig(room)
    const cameraZoom = shared.cameraZoom ?? ((zoom: number) => zoom)
    return {
      ...shared,
      // The room entry view uses the kitchen's entry zoom and follows the window, as in the kitchen.
      // Object framing keeps the shared room's own zoom.
      cameraZoom: (zoom, closeRoom, roomId) => cameraZoom(zoom, closeRoom, roomId) * (closeRoom
        ? scale.current * roomCameraZoom(1, true, 'kitchen') / roomCameraZoom(1, true, roomId)
        : 1),
    }
  }, [room])
  // A tapped object stays selected so the camera frames it, as `KitchenPreview` does for the kitchen.
  const [selection, setSelection] = useState<{ componentId: string; request: number } | null>(null)
  const selectedComponentId = onComponentSelect && installedRoomComponents(props.components, config.roomId)
    .some((component) => component.id === selection?.componentId) ? selection?.componentId ?? null : null
  useEffect(() => {
    if (!selectedComponentId) setSelection(null)
  }, [selectedComponentId])
  const selectComponent = (componentId: string) => {
    if (props.paused) return
    setSelection((previous) => ({ componentId, request: (previous?.request ?? 0) + 1 }))
    onComponentSelect?.(componentId)
  }
  const markers = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const root = markers.current
    return root ? smoothMarkers(root) : undefined
  }, [])
  return <div ref={markers} style={{ display: 'contents' }}>
    <ChoreRoomWorld config={config} {...props} selectedComponentId={selectedComponentId}
      onComponentSelect={onComponentSelect ? selectComponent : undefined}
      focusRequest={onComponentSelect ? { target: 'room', id: selection?.request ?? 0 } : props.focusRequest} />
  </div>
}

// The shared chore rooms place their + markers with `left` and `top`, which WebKit snaps to whole
// pixels, so markers jitter against the smoothly rotating room. The kitchen moves its markers with a
// sub-pixel transform. Mutation records arrive before the frame paints, so each position the room
// writes is moved into the kitchen's transform in the same frame.
function smoothMarkers(root: HTMLElement): () => void {
  const observer = new MutationObserver((records) => {
    for (const { target } of records) {
      if (!(target instanceof HTMLElement) || !target.classList.contains('world-hotspot')) continue
      const { left, top } = target.style
      if (!left.endsWith('px') || !top.endsWith('px') || (left === '0px' && top === '0px')) continue
      const x = Number.parseFloat(left)
      const y = Number.parseFloat(top)
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue
      target.style.left = '0px'
      target.style.top = '0px'
      target.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%)`
    }
  })
  observer.observe(root, { subtree: true, attributes: true, attributeFilter: ['style'] })
  return () => observer.disconnect()
}
