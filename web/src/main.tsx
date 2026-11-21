import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './styles/app.css'
import { App } from './App'
import { relay } from './state/relay'

void relay.init()

// Development hooks for the screenshot scripts.
if (import.meta.env.DEV) {
  const w = window as unknown as Record<string, unknown>
  w.__relay = relay
  void import('./media/media').then((m) => (w.__media = m))
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
