import { useEffect, useState } from 'react'
import { relay } from './state/relay'
import { Avatar, useCall, useRelay } from './ui/common'
import { Onboarding, Welcome } from './ui/Onboarding'
import { ContactList, ConversationList, useUnreadTotal } from './ui/Lists'
import { ChatView } from './ui/Chat'
import { AddContactSheet, ContactSheet, GroupSheet, NewGroupSheet } from './ui/Sheets'
import { MyCard } from './ui/MyCard'
import { MessageBanner } from './ui/Banner'
import { SettingsView } from './ui/Settings'
import { CallLayer } from './ui/Call'
import { Chat as ChatIcon, Gear, People, Phone, Plus } from './ui/Icons'

type Tab = 'chats' | 'contacts' | 'settings'
type SheetState =
  | { kind: 'add' }
  | { kind: 'mycode' }
  | { kind: 'contact'; fp: string }
  | { kind: 'group'; gid: string }
  | { kind: 'newgroup' }
  | null

const TITLES: Record<Tab, string> = { chats: 'Discussions', contacts: 'Contacts', settings: 'Réglages' }

export function App() {
  const snap = useRelay()
  const call = useCall()
  const [tab, setTab] = useState<Tab>('chats')
  const [sheet, setSheet] = useState<SheetState>(null)
  const [welcome, setWelcome] = useState(false)
  const [callHidden, setCallHidden] = useState(false)
  const unread = useUnreadTotal()

  useEffect(() => {
    document.title = unread ? `(${unread}) Soma Relay` : 'Soma Relay'
  }, [unread])

  useEffect(() => {
    if (call.phase === 'idle' || call.phase === 'incoming') setCallHidden(false)
  }, [call.phase])

  // The browser back button closes the open conversation on phones.
  useEffect(() => {
    const onPop = () => void relay.openConversation(null)
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  const prevPhase = usePrevious(snap.phase)
  useEffect(() => {
    if (prevPhase === 'onboarding' && snap.phase === 'ready') setWelcome(true)
  }, [prevPhase, snap.phase])

  if (snap.phase === 'loading') return <div className="onboard" aria-busy="true" />
  if (snap.phase === 'error')
    return (
      <div className="onboard">
        <div className="onboard-card">
          <h1>Oups</h1>
          <p>Impossible d’ouvrir le stockage local : {snap.error}</p>
          <button className="btn primary" onClick={() => location.reload()}>
            Réessayer
          </button>
        </div>
      </div>
    )
  if (snap.phase === 'onboarding') return <Onboarding />
  if (welcome) return <Welcome onDone={() => setWelcome(false)} />

  const open = (convId: string) => {
    if (!snap.activeConv && matchMedia('(max-width: 899px)').matches) history.pushState({ chat: convId }, '')
    void relay.openConversation(convId)
  }
  const back = () => {
    if (history.state?.chat) history.back()
    else void relay.openConversation(null)
  }
  const nodeLabel =
    snap.node === 'online'
      ? `NET en ligne · ${hostOf(snap.nodeBase)}`
      : snap.localBus
        ? 'BUS LOCAL · sans nœud'
        : snap.node === 'connecting'
          ? 'connexion au nœud…'
          : 'hors ligne · file d’attente'
  const dotClass = snap.node === 'online' || snap.localBus ? 'online' : snap.node === 'connecting' ? 'connecting' : ''

  return (
    <div className={`app two-pane${snap.activeConv ? ' chat-open' : ''}`}>
      <aside className="sidebar" aria-label="Navigation">
        <div className="top">
          <div className="bar glass">
            <div className="top-title">
              <h1>{TITLES[tab]}</h1>
              <div className="sub">
                <span className={`status-dot ${dotClass}`} aria-hidden="true" />
                {nodeLabel}
                {snap.profile !== 'default' ? ` · ${snap.profile}` : ''}
                {snap.engineKind === 'mock' ? ' · TEST' : ''}
              </div>
            </div>
            <button className="icon-btn me-btn" aria-label="Mon code" title="Ma carte" onClick={() => setSheet({ kind: 'mycode' })}>
              <Avatar id="me" name={snap.me?.name ?? '?'} size={36} />
            </button>
            {tab === 'chats' && (
              <button className="icon-btn" aria-label="Nouveau groupe" title="Nouveau groupe" onClick={() => setSheet({ kind: 'newgroup' })}>
                <People />
              </button>
            )}
            <button className="icon-btn strong" aria-label="Ajouter un contact" onClick={() => setSheet({ kind: 'add' })}>
              <Plus />
            </button>
          </div>
        </div>
        <div className="tabs glass" role="tablist" aria-label="Sections">
          <button role="tab" className="tab" aria-selected={tab === 'chats'} onClick={() => setTab('chats')}>
            <ChatIcon size={17} /> Discussions {unread > 0 && <span className="badge">{unread}</span>}
          </button>
          <button role="tab" className="tab" aria-selected={tab === 'contacts'} onClick={() => setTab('contacts')}>
            <People size={17} /> Contacts
          </button>
          <button role="tab" className="tab" aria-selected={tab === 'settings'} onClick={() => setTab('settings')}>
            <Gear size={17} /> Réglages
          </button>
        </div>
        {tab === 'chats' && <ConversationList onOpen={open} onNew={() => setSheet({ kind: 'add' })} />}
        {tab === 'contacts' && (
          <ContactList
            onOpen={open}
            onAdd={() => setSheet({ kind: 'add' })}
            onMyCode={() => setSheet({ kind: 'mycode' })}
            onGroup={() => setSheet({ kind: 'newgroup' })}
          />
        )}
        {tab === 'settings' && <SettingsView onMyCode={() => setSheet({ kind: 'mycode' })} />}
      </aside>
      <div className="main">
        {snap.activeConv ? (
          <ChatView
            key={snap.activeConv}
            convId={snap.activeConv}
            onBack={back}
            showBack
            onInfo={() =>
              setSheet(
                snap.activeConv!.startsWith('g:')
                  ? { kind: 'group', gid: snap.activeConv!.slice(2) }
                  : { kind: 'contact', fp: snap.activeConv! },
              )
            }
          />
        ) : (
          <div className="empty" style={{ marginTop: '22vh' }}>
            <svg width="96" height="96" viewBox="0 0 76 76" aria-hidden="true">
              <circle cx="38" cy="38" r="36" fill="none" stroke="var(--radar-line)" />
              <circle cx="38" cy="38" r="22" fill="none" stroke="var(--radar-line)" />
              <circle cx="38" cy="38" r="4" fill="var(--fg)" />
              <circle cx="64" cy="14" r="5" fill="var(--mesh)" />
              <path d="M38 38L54 26L64 14" stroke="var(--mesh)" strokeWidth="2" fill="none" strokeDasharray="3 3" />
            </svg>
            <h2>Choisis une discussion</h2>
            <p>Tout part chiffré de bout en bout, par le nœud ou en direct.</p>
          </div>
        )}
      </div>

      {sheet?.kind === 'add' && (
        <AddContactSheet
          onClose={() => setSheet(null)}
          onAdded={(fp) => {
            setSheet(null)
            open(fp)
          }}
        />
      )}
      {sheet?.kind === 'mycode' && (
        <MyCard
          onClose={() => setSheet(null)}
          onAdded={(fp) => {
            setSheet(null)
            setTab('chats')
            open(fp)
          }}
        />
      )}
      {sheet?.kind === 'contact' && <ContactSheet fp={sheet.fp} onClose={() => setSheet(null)} />}
      {sheet?.kind === 'group' && <GroupSheet gid={sheet.gid} onClose={() => setSheet(null)} />}
      {sheet?.kind === 'newgroup' && (
        <NewGroupSheet
          onClose={() => setSheet(null)}
          onCreated={(convId) => {
            setSheet(null)
            setTab('chats')
            open(convId)
          }}
        />
      )}

      {!callHidden && (
        <CallLayer
          onOpenChat={(fp) => {
            setCallHidden(true)
            open(fp)
          }}
        />
      )}
      {callHidden && call.phase !== 'idle' && (
        <button className="incoming glass" style={{ border: 0, cursor: 'pointer' }} onClick={() => setCallHidden(false)} aria-label="Revenir à l’appel">
          <span className="icon-btn strong" aria-hidden="true">
            <Phone />
          </span>
          <span className="who" style={{ textAlign: 'left' }}>
            <b>Appel en cours</b>
            <span>TOUCHE POUR REVENIR</span>
          </span>
        </button>
      )}
      <MessageBanner
        onOpen={(convId, msgId) => {
          relay.setJump(convId, msgId)
          setTab('chats')
          open(convId)
        }}
      />
      {snap.toast && (
        <div className="toast glass" role="status" key={snap.toast.id}>
          {snap.toast.text}
        </div>
      )}
    </div>
  )
}

function hostOf(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return url
  }
}

function usePrevious<T>(v: T): T | undefined {
  const [state, setState] = useState<{ cur: T; prev?: T }>({ cur: v })
  if (state.cur !== v) setState({ cur: v, prev: state.cur })
  return state.prev
}
