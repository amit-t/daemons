import { useEffect, useRef, useState } from 'react'
import { copyToClipboard } from '../clipboard'

// Inline email token that copies the address to the clipboard on click and
// flashes a transient "copied" / "copy failed" tag. Used in the detail drawer;
// the table reuses copyToClipboard directly because it also opens the drawer.
export function CopyEmail({ email, className }: { email: string; className?: string }) {
  const [state, setState] = useState<'idle' | 'copied' | 'failed'>('idle')
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => () => {
    if (timer.current) clearTimeout(timer.current)
  }, [])

  async function copy() {
    const ok = await copyToClipboard(email)
    setState(ok ? 'copied' : 'failed')
    if (timer.current) clearTimeout(timer.current)
    timer.current = setTimeout(() => setState('idle'), 1400)
  }

  return (
    <button
      type="button"
      className={`copy-email ${className ?? ''}`.trim()}
      onClick={copy}
      title="copy email to clipboard"
    >
      {email}
      <span className={`copy-tag ${state !== 'idle' ? 'show' : ''} ${state}`}>
        {state === 'failed' ? 'copy failed' : 'copied'}
      </span>
    </button>
  )
}
