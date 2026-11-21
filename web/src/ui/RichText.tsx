import { Fragment, type ReactNode } from 'react'
import { URL_RE } from '../state/sanitize'

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/** Marks `@Name` mentions and search hits inside a plain text piece. */
function decorate(text: string, names: string[], highlight: string | undefined, key: string): ReactNode[] {
  const parts: string[] = []
  if (names.length) parts.push(...names.map((n) => '@' + escapeRe(n)))
  if (highlight && highlight.trim().length >= 2) parts.push(escapeRe(highlight.trim()))
  if (!parts.length) return [text]
  const re = new RegExp(`(${parts.join('|')})`, 'gi')
  const hl = highlight?.trim().toLowerCase()
  return text.split(re).map((piece, i) => {
    if (i % 2 === 0) return piece
    if (hl && piece.toLowerCase() === hl) return <mark key={`${key}-${i}`}>{piece}</mark>
    return (
      <span className="mention" key={`${key}-${i}`}>
        {piece}
      </span>
    )
  })
}

/** Message text with clickable http(s) links, mentions and search highlights. */
export function RichText({ text, names = [], highlight }: { text: string; names?: string[]; highlight?: string }) {
  const out: ReactNode[] = []
  let last = 0
  let i = 0
  for (const m of text.matchAll(URL_RE)) {
    const at = m.index ?? 0
    if (at > last) out.push(<Fragment key={`t${i}`}>{decorate(text.slice(last, at), names, highlight, `t${i}`)}</Fragment>)
    out.push(
      <a key={`u${i}`} href={m[0]} target="_blank" rel="noopener noreferrer nofollow" onClick={(e) => e.stopPropagation()}>
        {decorate(m[0], [], highlight, `u${i}`)}
      </a>,
    )
    last = at + m[0].length
    i++
  }
  if (last < text.length) out.push(<Fragment key="end">{decorate(text.slice(last), names, highlight, 'end')}</Fragment>)
  return <>{out}</>
}
