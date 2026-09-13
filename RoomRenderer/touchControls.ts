export function installRoomTouchControls(root: Document): () => void {
  let tap: { id: number; button: HTMLButtonElement; x: number; y: number } | null = null
  const buttonAt = (target: EventTarget | null) => {
    const button = target instanceof Element ? target.closest('.native-room button') : null
    return button instanceof HTMLButtonElement && !button.disabled ? button : null
  }
  const start = (event: TouchEvent) => {
    const button = buttonAt(event.target)
    const touch = event.touches[0]
    tap = button && touch && event.touches.length === 1
      ? { id: touch.identifier, button, x: touch.clientX, y: touch.clientY }
      : null
  }
  const move = (event: TouchEvent) => {
    if (!tap) return
    const touch = Array.from(event.touches).find((touch) => touch.identifier === tap?.id)
    if (!touch || event.touches.length !== 1 || Math.hypot(touch.clientX - tap.x, touch.clientY - tap.y) > 10) tap = null
  }
  const cancel = () => { tap = null }
  const end = (event: TouchEvent) => {
    const candidate = tap
    tap = null
    if (!candidate || event.touches.length || !event.cancelable) return
    const touch = Array.from(event.changedTouches).find((touch) => touch.identifier === candidate.id)
    if (!touch || Math.hypot(touch.clientX - candidate.x, touch.clientY - candidate.y) > 10
      || buttonAt(root.elementFromPoint(touch.clientX, touch.clientY)) !== candidate.button) return
    // WebKit can retarget a rapid follow-up compatibility click to the previous control.
    // Activate the actual tapped button once and suppress that delayed synthetic click.
    event.preventDefault()
    candidate.button.click()
  }
  root.addEventListener('touchstart', start, { passive: true })
  root.addEventListener('touchmove', move, { passive: true })
  root.addEventListener('touchcancel', cancel, { passive: true })
  root.addEventListener('touchend', end, { passive: false })
  return () => {
    root.removeEventListener('touchstart', start)
    root.removeEventListener('touchmove', move)
    root.removeEventListener('touchcancel', cancel)
    root.removeEventListener('touchend', end)
  }
}
