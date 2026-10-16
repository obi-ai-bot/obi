import { useSyncExternalStore } from 'react';
import { BRANDS, type Brand } from './brands';
import { OBYS } from './mock';

// The Obyspheres you're in: each a place where your Oby works with other
// people's. Its picture in the icon strip is its logo (an image you gave it,
// or a brand's mark), else its name's first letter. admin: you made it or were
// made an admin of it (only people invited in can leave). members: the Obys in
// it besides yours (by their owner's name); invited: addresses asked in that
// haven't joined yet. domain: anyone with an address there can join by its link.
export type Sphere = {
  id: string; name: string; slug: string; brand?: Brand; image?: string;
  admin: boolean; members: string[]; invited: string[]; domain?: string;
};
// you (until there's sign-in)
export const ME = { name: 'Doti', email: 'doti@deskree.com' };
export const SUFFIX = '.obysphere.com';
export const urlOf = (s: Sphere) => `${s.slug}${SUFFIX}`;

let spheres: Sphere[] = [
  { id: 'deskree', name: 'Deskree', slug: 'deskree', brand: BRANDS.deskree, admin: true, members: OBYS.map((o) => o.name), invited: [], domain: 'deskree.com' },
];
const listeners = new Set<() => void>();
const set = (next: Sphere[]) => { spheres = next; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
export const useSpheres = () => useSyncExternalStore(subscribe, () => spheres);

// Its URL (deskree.obysphere.com): lowercase letters, digits and single hyphens, 3–30 long; made
// from the name as it's typed (Deskree × Avenga → deskree-avenga)
export const slugOf = (text: string) => text.toLowerCase().normalize('NFKD').replace(/\p{M}/gu, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+/, '').slice(0, 30);
// a hyphen left at its end while typing doesn't count
export const trimSlug = (slug: string) => slug.replace(/-+$/, '');
// how many are in it, you included
export const memberCount = (s: Sphere) => s.members.length + 1;
// mine: the Obysphere whose URL it is now (changing it, it isn't taken by itself)
export const slugProblem = (slug: string, mine?: string) => {
  const s = trimSlug(slug);
  if (s.length < 3) return 'At least 3 characters';
  // taken: someone else's (the mock's), the app's own words, or one of yours
  if (TAKEN.includes(s) || spheres.some((x) => x.slug === s && x.id !== mine)) return 'Taken';
  return null;
};
const TAKEN = ['avenga', 'tetrix', 'oby', 'app', 'www', 'admin', 'api', 'help', 'acme'];

// made by you: you're its admin; the people you invited are waiting to join
export function addSphere(s: Omit<Sphere, 'id' | 'admin' | 'members'>) {
  const id = `s${Date.now().toString(36)}`;
  set([...spheres, { ...s, slug: trimSlug(s.slug), id, admin: true, members: [] }]);
  return id;
}
// changed in its Settings (an admin's); deleted (an admin), or left (anyone
// else): gone from yours either way
export const updateSphere = (id: string, patch: Partial<Pick<Sphere, 'name' | 'slug' | 'image'>>) =>
  set(spheres.map((s) => (s.id === id ? { ...s, ...patch } : s)));
export const deleteSphere = (id: string) => {
  const image = spheres.find((s) => s.id === id)?.image;
  if (image) URL.revokeObjectURL(image);
  set(spheres.filter((s) => s.id !== id));
};
// from its settings' Members (an admin's): someone taken out, or an invite taken back
export const removeMember = (id: string, name: string) => set(spheres.map((s) => (s.id === id ? { ...s, members: s.members.filter((m) => m !== name) } : s)));
export const cancelInvite = (id: string, email: string) => set(spheres.map((s) => (s.id === id ? { ...s, invited: s.invited.filter((e) => e !== email) } : s)));
export const invite = (id: string, emails: string[]) =>
  set(spheres.map((s) => (s.id === id ? { ...s, invited: [...s.invited, ...emails.filter((e) => !s.invited.some((x) => x.toLowerCase() === e.toLowerCase()))] } : s)));
