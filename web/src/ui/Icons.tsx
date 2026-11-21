// Line icons from the Fusion artboards (24 px grid, round caps).
import type { SVGProps } from 'react'

type P = SVGProps<SVGSVGElement> & { size?: number }

const base = (size: number, rest: SVGProps<SVGSVGElement>) => ({
  width: size,
  height: size,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
  ...rest,
})

export const Back = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M15 5l-7 7 7 7" />
  </svg>
)
export const Phone = ({ size = 19, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9}>
    <path d="M5 4h4l2 5-2.5 1.5a11 11 0 005 5L15 13l5 2v4a2 2 0 01-2 2A16 16 0 013 6a2 2 0 012-2z" />
  </svg>
)
export const Video = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9}>
    <rect x="3" y="6" width="13" height="12" rx="2.5" />
    <path d="M16 10l5-3v10l-5-3" />
  </svg>
)
export const Plus = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M12 5v14M5 12h14" />
  </svg>
)
export const Mic = ({ size = 19, ...r }: P) => (
  <svg {...base(size, r)}>
    <rect x="9" y="3" width="6" height="11" rx="3" />
    <path d="M5 11a7 7 0 0014 0M12 18v3" />
  </svg>
)
export const MicOff = ({ size = 22, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9}>
    <rect x="9" y="3" width="6" height="11" rx="3" />
    <path d="M5 11a7 7 0 0014 0M12 18v3M4 4l16 16" />
  </svg>
)
export const Speaker = ({ size = 22, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9}>
    <path d="M4 9v6h4l5 4V5L8 9zM16 9a4 4 0 010 6M18.5 6.5a8 8 0 010 11" />
  </svg>
)
export const Chat = ({ size = 22, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9}>
    <path d="M4 5h16v11H9l-5 4z" />
  </svg>
)
export const Send = ({ size = 19, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M12 19V5M6 11l6-6 6 6" />
  </svg>
)
export const Play = ({ size = 13, ...r }: P) => (
  <svg {...base(size, r)} fill="currentColor" stroke="none">
    <path d="M7 4l13 8-13 8z" />
  </svg>
)
export const Pause = ({ size = 13, ...r }: P) => (
  <svg {...base(size, r)} fill="currentColor" stroke="none">
    <rect x="6" y="4" width="4" height="16" rx="1" />
    <rect x="14" y="4" width="4" height="16" rx="1" />
  </svg>
)
export const Lock = ({ size = 12, ...r }: P) => (
  <svg {...base(size, r)}>
    <rect x="5" y="11" width="14" height="10" rx="2" />
    <path d="M8 11V8a4 4 0 018 0v3" />
  </svg>
)
export const Chevron = ({ size = 16, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M6 15l6-6 6 6" />
  </svg>
)
export const Close = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M6 6l12 12M18 6L6 18" />
  </svg>
)
export const Search = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)}>
    <circle cx="11" cy="11" r="6.5" />
    <path d="M20 20l-4-4" />
  </svg>
)
export const Qr = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <rect x="4" y="4" width="6" height="6" rx="1.5" />
    <rect x="14" y="4" width="6" height="6" rx="1.5" />
    <rect x="4" y="14" width="6" height="6" rx="1.5" />
    <path d="M14 14h2v2M20 14v.01M14 20h2M18 18h2v2" />
  </svg>
)
export const Gear = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1" />
  </svg>
)
export const People = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <circle cx="9" cy="8" r="3.5" />
    <path d="M2.5 20a6.5 6.5 0 0113 0M16 4.5a3.5 3.5 0 010 7M18 14.5a6.5 6.5 0 013.5 5.5" />
  </svg>
)
export const Image = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <rect x="3" y="4" width="18" height="16" rx="3" />
    <circle cx="9" cy="10" r="1.8" />
    <path d="M21 16l-5-5-9 9" />
  </svg>
)
export const File = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <path d="M14 3H7a2 2 0 00-2 2v14a2 2 0 002 2h10a2 2 0 002-2V8z" />
    <path d="M14 3v5h5" />
  </svg>
)
export const Camera = ({ size = 20, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <path d="M4 8h3l2-3h6l2 3h3v11H4z" />
    <circle cx="12" cy="13" r="3.5" />
  </svg>
)
export const Reply = ({ size = 17, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M10 8L5 12l5 4M5 12h9a5 5 0 015 5v1" />
  </svg>
)
export const Check = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M5 12.5l4.5 4.5L19 7.5" />
  </svg>
)
export const Shield = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <path d="M12 3l8 3v6c0 4.5-3.4 8.2-8 9-4.6-.8-8-4.5-8-9V6z" />
    <path d="M8.5 12l2.5 2.5 4.5-5" />
  </svg>
)
export const Radio = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <circle cx="12" cy="12" r="2" />
    <path d="M7.8 7.8a6 6 0 000 8.4M16.2 7.8a6 6 0 010 8.4M5 5a10 10 0 000 14M19 5a10 10 0 010 14" />
  </svg>
)
export const Copy = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <rect x="8" y="8" width="12" height="12" rx="2.5" />
    <path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2" />
  </svg>
)
export const Download = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)}>
    <path d="M12 4v11M7 10l5 5 5-5M5 20h14" />
  </svg>
)
export const Trash = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3" />
  </svg>
)
export const Hang = ({ size = 24, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9} style={{ transform: 'rotate(135deg)' }}>
    <path d="M5 4h4l2 5-2.5 1.5a11 11 0 005 5L15 13l5 2v4a2 2 0 01-2 2A16 16 0 013 6a2 2 0 012-2z" />
  </svg>
)
export const CameraOff = ({ size = 22, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.9}>
    <rect x="3" y="6" width="13" height="12" rx="2.5" />
    <path d="M16 10l5-3v10l-5-3M3 3l18 18" />
  </svg>
)
export const Smile = ({ size = 18, ...r }: P) => (
  <svg {...base(size, r)} strokeWidth={1.8}>
    <circle cx="12" cy="12" r="9" />
    <path d="M8.5 14.5a4.5 4.5 0 007 0M9 9.5v.01M15 9.5v.01" />
  </svg>
)
