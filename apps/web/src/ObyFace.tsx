import { useId } from 'react';

// Oby as a small icon, a silhouette of the mascot: a soft square a little wider
// than it's tall, two tall eyes, and two short ears on its top, each about a
// quarter of the way in, their inner edges near upright and their tips leaning
// toward each other.
// ObyIcon: a line drawing of Oby, for menus (the + panel's Add other Obys).
// ObyFace is filled like Oby itself.
// All in a 24-unit square: the body 21 × 16.5 at the bottom, the ears ~2.5 over it.
const EAR_L = 'M5 6.6 L7.9 3.6 L8.9 6.6 Z';
const EAR_R = 'M19 6.6 L16.1 3.6 L15.1 6.6 Z';
const Ears = ({ fill }: { fill: string }) => (
  // drawn with a round-cornered stroke of their own colour, so their tips are soft
  <g fill={fill} stroke={fill} strokeWidth="1.2" strokeLinejoin="round">
    <path d={EAR_L} /><path d={EAR_R} />
  </g>
);

export function ObyIcon({ size = 20 }: { size?: number }) {
  const mask = useId();
  // the line drawing: the body's outline breaks under each ear, so the two read as one shape
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <mask id={mask}>
        <rect width="24" height="24" fill="#fff" />
        <path d="M6.4 7.8 L8 5.9 L8.5 7.8 Z" fill="#000" />
        <path d="M17.6 7.8 L16 5.9 L15.5 7.8 Z" fill="#000" />
      </mask>
      <rect x="3" y="7" width="18" height="14" rx="4.5" stroke="currentColor" strokeWidth="1.5" mask={`url(#${mask})`} />
      <path d="M5.6 7.2 L8 4.5 L8.8 7 M18.4 7.2 L16 4.5 L15.2 7" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" strokeLinecap="round" />
      <rect x="6.9" y="11" width="2.2" height="4" rx="1.1" fill="currentColor" />
      <rect x="14.3" y="11" width="2.2" height="4" rx="1.1" fill="currentColor" />
    </svg>
  );
}

// badge: the small one on an owner's picture. Full-height ears would eat the
// face at that size, so its ears are stubs (about half as tall), on the same
// square body, its eyes a little closer together so they still read.
const BADGE_EAR_L = 'M4.6 5.2 L7.4 3.6 L8.4 5.2 Z';
const BADGE_EAR_R = 'M19.4 5.2 L16.6 3.6 L15.6 5.2 Z';
export function ObyFace({ size = 24, badge = false }: { size?: number; badge?: boolean }) {
  if (badge) {
    return (
      <svg width={size} height={size} viewBox="0 0 24 24" overflow="visible" aria-hidden="true">
        {/* the cutout in the picture under it: the same shape, a little bigger,
            in the window's colour (its width is set in app.css) */}
        <g className="oby-badge-cut" strokeLinejoin="round">
          <path d={BADGE_EAR_L} /><path d={BADGE_EAR_R} />
          <rect x="1.5" y="4.5" width="21" height="17" rx="5" />
        </g>
        <g fill="#f1f1ee" stroke="#f1f1ee" strokeWidth="1.2" strokeLinejoin="round">
          <path d={BADGE_EAR_L} /><path d={BADGE_EAR_R} />
        </g>
        <rect x="1.5" y="4.5" width="21" height="17" rx="5" fill="#f1f1ee" />
        <rect x="7.4" y="10" width="2.6" height="5" rx="1.3" fill="#0d0d0e" />
        <rect x="14" y="10" width="2.6" height="5" rx="1.3" fill="#0d0d0e" />
      </svg>
    );
  }
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <Ears fill="#f1f1ee" />
      <rect x="1.5" y="6" width="21" height="16.5" rx="5" fill="#f1f1ee" />
      <rect x="6" y="10.6" width="2.8" height="5" rx="1.4" fill="#0d0d0e" />
      <rect x="14.6" y="10.6" width="2.8" height="5" rx="1.4" fill="#0d0d0e" />
    </svg>
  );
}

// Someone else's Oby over the first of its run in a conversation: its
// owner's picture and its name
export function PeerByline({ name }: { name: string }) {
  return (
    <span className="peer-by">
      <OwnerAvatar name={name} size={22} />
      <span>{name}’s Oby</span>
    </span>
  );
}

// Someone else's Oby: its owner's round picture (initials on a colour picked
// from their name, until there are real photos), with a small Oby at the
// bottom right saying it's their Oby, not them. The owner is what tells two
// Obys apart; an Oby this small can't show its own colour or face clearly.
const AVATAR_COLORS = ['#3a5a8c', '#7a4a8c', '#2f7a6a', '#8c5a3a', '#8c3a52', '#5a6a2f', '#3a7a8c', '#6a4a3a'];
// djb2: spreads similar names (Dima, Daniel) over different colours
const hash = (s: string) => [...s].reduce((h, c) => ((h * 33) ^ c.charCodeAt(0)) >>> 0, 5381);
export function OwnerAvatar({ name, size = 28, badge = true }: { name: string; size?: number; badge?: boolean }) {
  const hue = hash(name) % AVATAR_COLORS.length;
  const initials = name.split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase();
  return (
    <span className="owner-avatar" style={{ width: size, height: size, background: AVATAR_COLORS[hue] }} aria-hidden="true">
      {initials}
      {badge && <span className="owner-avatar-oby"><ObyFace size={Math.round(size * 0.5)} badge /></span>}
    </span>
  );
}

// Everyone in a conversation, side by side and overlapping: up to 5 pictures,
// then how many more. Only the last carries the Oby badge (they're all Obys).
export function AvatarStack({ names, size = 22, max = 5 }: { names: string[]; size?: number; max?: number }) {
  const shown = names.slice(0, max), more = names.length - shown.length;
  return (
    <span className="avatar-stack" aria-label={names.map((n) => `${n}’s Oby`).join(', ')}>
      {shown.map((n, i) => <OwnerAvatar key={n} name={n} size={size} badge={i === shown.length - 1} />)}
      {more > 0 && <span className="avatar-more" style={{ height: size, minWidth: size }}>+{more}</span>}
    </span>
  );
}
