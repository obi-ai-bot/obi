import { useEffect, useId, useRef, useState } from 'react';
import { ObyFace } from './ObyFace';

// Oby's face in a conversation while it works: the flat face doing what the
// mascot's Loading does (oby/oby.html), in 2D. It spins round as it shrinks into
// a ball, which melts into three dots that bounce in a wave while Oby works;
// when its words land the dots run back together into a ball that swells into
// the face as it spins to face you. Values are damped springs chasing targets
// set on a timeline, like the mascot's, with its timings and spring presets.
// At rest it's ObyFace itself, so there's nothing to jump when it settles.

// [stiffness, damping], from the mascot's PRESET
const PRESET = { body: [120, 16], jelly: [260, 13], pop: [280, 15], fast: [500, 30], slow: [26, 10], melt: [55, 13], spread: [70, 7] } as const;
type Preset = keyof typeof PRESET;
const TAU = Math.PI * 2;
// each value at rest, and the spring it moves on unless a key says otherwise
const REST = {
  ry: [0, 'body'], sq: [1, 'jelly'], inflate: [0.17, 'pop'], scale: [1, 'body'],
  dR: [0, 'pop'], dSpread: [0, 'spread'], dBounce: [0, 'body'],
} as const satisfies Record<string, readonly [number, Preset]>;
type Name = keyof typeof REST;
// the mascot's Loading keys: [time (s), targets, spring]
const KEYS: [number, Partial<Record<Name, number>>, Preset][] = [
  [0, { ry: -0.3, sq: 0.92 }, 'fast'],                                // wind-up
  [0.2, { ry: Math.PI, sq: 1, inflate: 1, scale: 0.5 }, 'body'],      // spins round as it shrinks into a ball
  [0.5, { dR: 1 }, 'pop'],
  [0.5, { scale: 0.04 }, 'melt'],                                     // the ball melts...
  [0.6, { dSpread: 1 }, 'spread'],                                    // ...and pulls apart into dots
  [1.1, { dBounce: 1 }, 'slow'],
  [4.0, { dBounce: 0 }, 'fast'],
  [4.1, { dSpread: 0 }, 'spread'],                                    // dots run back together
  [4.25, { scale: 0.5 }, 'melt'],                                     // into a ball
  [4.45, { inflate: 0.17, scale: 1, ry: TAU }, 'body'],               // that swells back into the face as it spins to face you
  [4.5, { dR: 0 }, 'body'],
];
// while Oby works it holds just before WRAP_UP (the dots bouncing); once its
// words land it skips to WRAP_UP, and is done after the last key, once settled
const WRAP_UP = 4.0, LAST = 4.5;

// The face in its 24-unit square (as ObyFace): body 21 × 16.5 centred here
const CX = 12, CY = 14.25;
// the dots, in the mascot's proportions to its body: 0.4 apart, 0.1 across
const GAP = 8.4, DOT_R = 2.1, HOP = 3;
const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

type Spring = { v: number; vel: number; to: number; k: number; c: number };

export default function ObyFaceLive({ live, size = 22 }: { live: boolean; size?: number }) {
  const [active, setActive] = useState(live);
  const liveRef = useRef(live);
  liveRef.current = live;
  useEffect(() => { if (live) setActive(true); }, [live]);

  const goo = useId();
  const svg = useRef<SVGSVGElement>(null);
  // reduced motion: no spin, melt or bounce, just three still dots while Oby works
  const [still] = useState(() => matchMedia('(prefers-reduced-motion: reduce)').matches);

  useEffect(() => {
    if (!active || still) return;
    const root = svg.current!;
    const q = (s: string) => root.querySelector(s) as SVGElement;
    const body = q('[data-body]'), shape = q('[data-shape]'), ears = q('[data-ears]'), eyes = q('[data-eyes]');
    const blob = q('[data-goo]');
    const dots = [...root.querySelectorAll('[data-dot]')] as SVGCircleElement[];

    const s = Object.fromEntries(Object.entries(REST).map(([n, [v, p]]) =>
      [n, { v, vel: 0, to: v, k: PRESET[p][0], c: PRESET[p][1] }])) as Record<Name, Spring>;
    const V = (n: Name) => s[n].v;
    // the keys in order: idx is the next one due
    let t = 0, idx = 0;
    const advance = (to: number) => {
      for (; idx < KEYS.length && KEYS[idx][0] <= to; idx++) {
        const [, set, p] = KEYS[idx];
        for (const [n, v] of Object.entries(set) as [Name, number][]) {
          s[n].to = v; s[n].k = PRESET[p][0]; s[n].c = PRESET[p][1];
        }
      }
      t = to;
    };

    const draw = (clock: number) => {
      const b = clamp01((V('inflate') - 0.17) / 0.83);   // 0 the face … 1 a ball
      const melt = clamp01(1 - (V('scale') - 0.04) / 0.46);
      const cos = Math.cos(V('ry'));
      // the spin: a flat face narrows to its edge; a ball stays round
      const sx = lerp(Math.abs(cos), 1, b) * V('scale') / Math.sqrt(V('sq'));
      const sy = V('scale') * V('sq');
      const xf = `translate(${CX} ${CY}) scale(${sx} ${sy}) translate(${-CX} ${-CY})`;
      body.setAttribute('transform', xf);
      eyes.setAttribute('transform', xf);
      const w = lerp(21, 17, b), h = lerp(16.5, 17, b);
      shape.setAttribute('x', String(CX - w / 2)); shape.setAttribute('y', String(CY - h / 2));
      shape.setAttribute('width', String(w)); shape.setAttribute('height', String(h));
      shape.setAttribute('rx', String(lerp(5, 8.5, b)));
      // the ears fold down into the ball
      ears.setAttribute('transform', `translate(0 6.6) scale(1 ${1 - b}) translate(0 -6.6)`);
      // eyes: only on the front, and gone as it melts
      eyes.setAttribute('opacity', String(clamp01(cos * 3) * (1 - melt)));
      // the dots, bunched up bigger so together they fill the ball they came from
      const k = V('dR'), spread = V('dSpread');
      const R = Math.max(0, DOT_R * (1 + 0.9 * (1 - spread)) * k);
      dots.forEach((d, i) => {
        const hop = V('dBounce') * HOP * Math.max(0, Math.sin(clock * 7 - i * 0.9));
        d.setAttribute('cx', String(CX + (i - 1) * GAP * spread));
        d.setAttribute('cy', String(CY - hop));
        d.setAttribute('r', String(R));
      });
      // gooey only while there are dots, so the face itself stays crisp
      blob.setAttribute('filter', k > 0.01 ? `url(#${goo})` : 'none');
    };

    let clock = 0, prev = performance.now(), drawn = -1, raf = 0;
    advance(0);
    const frame = (now: number) => {
      const dt = Math.min(0.05, (now - prev) / 1000);
      prev = now;
      clock += dt;
      const live = liveRef.current;
      if (live && t >= WRAP_UP) { idx = 0; advance(0); }  // back to work while coming together: start over
      if (!live && t < WRAP_UP) { idx = KEYS.findIndex(([at]) => at >= WRAP_UP); t = WRAP_UP; }  // words in: skip to coming together
      advance(live ? Math.min(t + dt, WRAP_UP - 1e-3) : t + dt);
      // springs, in small steps so the stiff ones stay steady
      const n = Math.ceil(dt / (1 / 240)), h = dt / n;
      for (let i = 0; i < n; i++) for (const sp of Object.values(s)) {
        sp.vel += (sp.k * (sp.to - sp.v) - sp.c * sp.vel) * h;
        sp.v += sp.vel * h;
      }
      if (!live && t > LAST && Object.values(s).every((sp) => Math.abs(sp.to - sp.v) < 1e-3 && Math.abs(sp.vel) < 1e-2)) {
        setActive(false);  // settled: the still face takes over
        return;
      }
      // drawn at 30fps, as the mascot (the springs still step every frame)
      if (clock - drawn >= 1 / 30 - 1e-3) { drawn = clock; draw(clock); }
      raf = requestAnimationFrame(frame);
    };
    draw(0);
    raf = requestAnimationFrame(frame);
    return () => cancelAnimationFrame(raf);
  }, [active, still, goo]);

  if (still) return live ? (
    <svg width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      {[-1, 0, 1].map((i) => <circle key={i} cx={CX + i * GAP} cy={CY} r={DOT_R} fill="#f1f1ee" />)}
    </svg>
  ) : <ObyFace size={size} />;
  if (!active) return <ObyFace size={size} />;
  return (
    <svg ref={svg} width={size} height={size} viewBox="0 0 24 24" overflow="visible" aria-hidden="true">
      <defs>
        {/* blur, then a hard alpha edge: shapes near each other run together like liquid */}
        <filter id={goo} x="-12" y="-12" width="48" height="48" filterUnits="userSpaceOnUse">
          <feGaussianBlur stdDeviation="0.9" />
          <feColorMatrix values="1 0 0 0 0  0 1 0 0 0  0 0 1 0 0  0 0 0 18 -7" />
        </filter>
      </defs>
      <g data-goo="" fill="#f1f1ee">
        <g data-body="">
          <g data-ears="" stroke="#f1f1ee" strokeWidth="1.2" strokeLinejoin="round">
            <path d="M5 6.6 L7.9 3.6 L8.9 6.6 Z" /><path d="M19 6.6 L16.1 3.6 L15.1 6.6 Z" />
          </g>
          <rect data-shape="" x="1.5" y="6" width="21" height="16.5" rx="5" />
        </g>
        <circle data-dot="" cx={CX} cy={CY} r="0" /><circle data-dot="" cx={CX} cy={CY} r="0" /><circle data-dot="" cx={CX} cy={CY} r="0" />
      </g>
      <g data-eyes="" fill="#0d0d0e">
        <rect x="6" y="10.6" width="2.8" height="5" rx="1.4" />
        <rect x="14.6" y="10.6" width="2.8" height="5" rx="1.4" />
      </g>
    </svg>
  );
}
