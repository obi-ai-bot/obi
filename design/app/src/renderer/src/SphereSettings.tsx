import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, Mail, X } from 'lucide-react';
import { Group, Row, SettingsPage, Value } from './SettingsView';
import SphereTile from './SphereTile';
import { OwnerAvatar } from './ObyFace';
import { ME, SUFFIX, cancelInvite, deleteSphere, memberCount, removeMember, trimSlug, slugOf, slugProblem, updateSphere, urlOf, useSpheres, type Sphere } from './spheres';

export const sphereSettingsLabel = (id: string, spheres: Sphere[]) => `${spheres.find((s) => s.id === id)?.name ?? ''} settings`;


// An Obysphere's settings, opened from its ⋮ (Settings), in the view as the
// app's are, under its name ("Deskree settings"); the side panel stays on the
// Obysphere. id: which Obysphere.
export default function SphereSettings({ id, ...frame }: {
  id: string;
  leaving: boolean;
  covered?: boolean;
  onClose: () => void;
  onGone: () => void;
}) {
  const spheres = useSpheres();
  const sphere = spheres.find((s) => s.id === id);
  // its name kept while its page goes, deleted or left (Home takes the page away)
  const title = useRef('');
  if (sphere) title.current = sphereSettingsLabel(id, spheres);
  return (
    <SettingsPage title={title.current} {...frame}>
      {sphere && <Settings key={sphere.id} sphere={sphere} />}
    </SettingsPage>
  );
}

// Its avatar, name and URL (its admins change them; anyone else sees them),
// then deleting it (an admin) or leaving it (anyone else). Each change is kept
// as it's made, as macOS settings are, and says so for a moment ("Saved").
function Settings({ sphere }: { sphere: Sphere }) {
  const { admin } = sphere;
  const file = useRef<HTMLInputElement>(null);
  const [saved, setSaved] = useState<'avatar' | 'name' | 'url' | null>(null);
  useEffect(() => {
    if (!saved) return;
    const t = setTimeout(() => setSaved(null), 2000);
    return () => clearTimeout(t);
  }, [saved]);
  const savedNote = (what: typeof saved) => (saved === what ? <span className="set-saved"><Check size={12} strokeWidth={2} />Saved</span> : undefined);
  const setImage = (image: string | undefined) => {
    if (sphere.image) URL.revokeObjectURL(sphere.image);
    updateSphere(sphere.id, { image });
    setSaved('avatar');
  };
  // the name and URL as they're typed: kept once you leave the field, if
  // they'll do (and changed); else back to what they were
  const [name, setName] = useState(sphere.name);
  const [slug, setSlug] = useState(sphere.slug);
  useEffect(() => setName(sphere.name), [sphere.name]);
  useEffect(() => setSlug(sphere.slug), [sphere.slug]);
  const problem = slug !== sphere.slug ? slugProblem(slug, sphere.id) : null;
  const saveName = () => {
    const n = name.trim();
    if (n.length < 2 || n === sphere.name) setName(sphere.name);
    else { updateSphere(sphere.id, { name: n }); setSaved('name'); }
  };
  const saveSlug = () => {
    const s = trimSlug(slug);
    if (problem || !s || s === sphere.slug) setSlug(sphere.slug);
    else { updateSphere(sphere.id, { slug: s }); setSaved('url'); }
  };
  // Enter keeps it (by leaving the field); Esc puts it back
  const keys = (undo: () => void) => (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') e.currentTarget.blur();
    if (e.key === 'Escape') undo();
  };
  const [confirming, setConfirming] = useState(false);

  return <>
    <Group
      i={1}
      footer={admin ? 'Its URL is in every invite link: a new one stops the old links working.' : 'Only its admins can change these.'}
    >
      {/* the avatar, at the right: a click picks a new image; its badge takes the image out */}
      <Row label="Avatar" about={savedNote('avatar') ?? (admin ? 'A square image, at least 128px' : undefined)}>
        {admin ? (
          <span className="sphere-logo set-avatar">
            <button className="sphere-logo-pick" aria-label="Change avatar" title="Change avatar" onClick={() => file.current?.click()}>
              <SphereTile name={sphere.name} brand={sphere.brand} image={sphere.image} />
            </button>
            {sphere.image && <button className="sphere-logo-badge" aria-label="Remove avatar" title="Remove avatar" onClick={() => setImage(undefined)}><X size={12} strokeWidth={2} /></button>}
            <input
              ref={file}
              type="file"
              accept="image/*"
              hidden
              onChange={(e) => {
                const f = e.currentTarget.files?.[0];
                if (f) setImage(URL.createObjectURL(f));
                e.currentTarget.value = '';
              }}
            />
          </span>
        ) : <span className="set-avatar"><SphereTile name={sphere.name} brand={sphere.brand} image={sphere.image} /></span>}
      </Row>
      <Row label="Name" about={savedNote('name')}>
        {admin
          ? <input className="set-field set-wide" value={name} maxLength={40} onChange={(e) => setName(e.target.value)} onBlur={saveName} onKeyDown={keys(() => setName(sphere.name))} aria-label="Name" spellCheck={false} />
          : <Value>{sphere.name}</Value>}
      </Row>
      <Row label="Obysphere URL" about={problem ? <span id="sphere-url-problem" className="set-problem">{problem === 'Taken' ? `${slug}${SUFFIX} is taken` : problem}</span> : savedNote('url')}>
        {admin ? (
          <label className={`set-field set-address${problem ? ' is-bad' : ''}`}>
            <input value={slug} maxLength={30} onChange={(e) => setSlug(slugOf(e.target.value))} onBlur={saveSlug} onKeyDown={keys(() => setSlug(sphere.slug))} aria-label="Obysphere URL" aria-invalid={!!problem || undefined} aria-describedby={problem ? 'sphere-url-problem' : undefined} spellCheck={false} />
            <span className="sphere-suffix">{SUFFIX}</span>
          </label>
        ) : <Value>{urlOf(sphere)}</Value>}
      </Row>
    </Group>
    {/* who's in it: you first, then the others, then who's been invited; an
        admin can take someone out (Remove) or an invite back (Cancel invite) */}
    <Group i={2} title={`Members · ${memberCount(sphere)}`}>
      <div className="set-row set-member">
        <OwnerAvatar name={ME.name} size={28} badge={false} />
        <span className="set-label">{ME.name} (you)<span className="set-about">{ME.email}</span></span>
        <span className="set-role">{admin ? 'Admin' : 'Member'}</span>
      </div>
      {sphere.members.map((m) => (
        <div key={m} className="set-row set-member">
          <OwnerAvatar name={m} size={28} badge={false} />
          <span className="set-label">{m}<span className="set-about">{m.toLowerCase()}@{sphere.domain ?? 'deskree.com'}</span></span>
          <span className="set-role">Member</span>
          {admin && <button className="set-button is-danger set-member-action" onClick={() => removeMember(sphere.id, m)} aria-label={`Remove ${m}`}>Remove</button>}
        </div>
      ))}
      {sphere.invited.map((e) => (
        <div key={e} className="set-row set-member">
          <span className="invited-mark set-invited"><Mail size={14} strokeWidth={1.8} /></span>
          <span className="set-label is-muted">{e}</span>
          <span className="set-role">Invited</span>
          {admin && <button className="set-button set-member-action" onClick={() => cancelInvite(sphere.id, e)} aria-label={`Cancel invite to ${e}`}>Cancel invite</button>}
        </div>
      ))}
    </Group>
    {/* last, set apart: what it does, then its button under it at the left */}
    <Group i={3}>
      <div className="set-row set-danger">
        <span className="set-label">
          {admin ? 'Delete Obysphere' : `Leave ${sphere.name}`}
          <span className="set-about">{admin ? `Deletes ${sphere.name} for all ${memberCount(sphere)} members. You can’t undo this.` : 'You’ll lose access until someone invites you back.'}</span>
        </span>
        <button className="set-button is-danger" onClick={() => setConfirming(true)}>{admin ? 'Delete' : 'Leave'}</button>
      </div>
    </Group>
    {confirming && <ConfirmModal sphere={sphere} onClose={() => setConfirming(false)} />}
  </>;
}

// Before it's deleted (or left): what goes with it, and, to delete, its name
// typed in, so it isn't done by a slip. Esc, Cancel, the x or a click outside
// closes it.
function ConfirmModal({ sphere, onClose }: { sphere: Sphere; onClose: () => void }) {
  const [typed, setTyped] = useState('');
  const leaving = !sphere.admin;
  const ready = leaving || typed.trim() === sphere.name;
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); close.current(); } };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, []);
  return createPortal(
    <div className="modal-backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <form className="modal is-small" role="alertdialog" aria-modal="true" aria-labelledby="confirm-title" aria-describedby="confirm-what" onSubmit={(e) => { e.preventDefault(); if (ready) deleteSphere(sphere.id); }}>
        <header className="modal-head">
          <h2 id="confirm-title">{leaving ? `Leave ${sphere.name}?` : `Delete ${sphere.name}?`}</h2>
          <button type="button" className="icon-button" aria-label="Close" onClick={onClose}><X size={16} strokeWidth={1.6} /></button>
        </header>
        <p id="confirm-what" className="modal-lede">
          {leaving
            ? `You’ll lose access to ${sphere.name} and everything its Obys share. To come back, someone has to invite you again.`
            : `This deletes ${sphere.name} for all ${memberCount(sphere)} members, cancels open invites and erases everything its Obys shared. You can’t undo this.`}
        </p>
        {!leaving && <>
          <label className="modal-label" htmlFor="confirm-name">Type <strong>{sphere.name}</strong> to confirm</label>
          <input id="confirm-name" className="modal-field" autoFocus value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" spellCheck={false} />
        </>}
        <div className="modal-actions">
          <button type="button" className="set-button" autoFocus={leaving} onClick={onClose}>Cancel</button>
          <button type="submit" className="modal-primary is-danger" disabled={!ready}>{leaving ? 'Leave' : 'Delete Obysphere'}</button>
        </div>
      </form>
    </div>,
    document.body,
  );
}
