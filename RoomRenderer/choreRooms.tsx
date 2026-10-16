import { useMemo, useRef } from 'react'
import type { ReactElement } from 'react'
import ChoreRoomWorld from '@roomlings-web/src/ChoreRoomWorld.tsx'
import type { ChoreRoomConfig, ChoreRoomWorldProps } from '@roomlings-web/src/ChoreRoomWorld.tsx'
import BathroomWorld from '@roomlings-web/src/BathroomWorld.tsx'
import LivingRoomWorld from '@roomlings-web/src/LivingRoomWorld.tsx'
import { roomCameraZoom } from '@roomlings-web/src/camera.ts'

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
export function ScaledChoreRoom({ room, roomZoom, ...props }: { room: SharedRoom; roomZoom: number }
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
  return <ChoreRoomWorld config={config} {...props} />
}
