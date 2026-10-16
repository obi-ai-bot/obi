import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, ImagePlus, X } from 'lucide-react';
import { useScrollThumb } from './useScrollThumb';
import EmailField, { EMAIL, useEmails } from './EmailField';
import SphereTile from './SphereTile';
import { SUFFIX, addSphere, slugOf, slugProblem, trimSlug } from './spheres';

// Addresses anyone can have: no org behind them, so no "anyone there can join"
const PERSONAL = ['gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'live.com', 'icloud.com', 'me.com', 'yahoo.com', 'proton.me', 'protonmail.com'];

// Making an Obysphere (the + in the icon strip): its name; its URL, made
// from the name until you change it, said at once to be free or taken; a
// logo, if you have one (else the name's first letter); people to invite, if
// any yet; and whether anyone with an address at your org can join by its
// link (on for a work address; not offered for a personal one). You're its
// admin. Esc, the x or a click outside closes it.
export default function CreateSphereModal({ email, onCreated, onClose }: {
  email: string;  // yours: its domain is the org's
  onCreated: (id: string) => void;
  onClose: () => void;
}) {
  const domain = email.split('@')[1]?.toLowerCase();
  const work = !!domain && !PERSONAL.includes(domain);
  const [name, setName] = useState('');
  // the URL follows the name until it's typed in itself
  const [ownSlug, setOwnSlug] = useState<string | null>(null);
  const slug = ownSlug ?? slugOf(name);
  const [image, setImage] = useState<string>();
  // closed without making it: the picked image goes too (made, the Obysphere keeps it)
  const kept = useRef<string | undefined>(undefined);
  const shown = useRef(image);
  shown.current = image;
  useEffect(() => () => { if (shown.current && shown.current !== kept.current) URL.revokeObjectURL(shown.current); }, []);
  const [anyone, setAnyone] = useState(work);
  const list = useEmails();
  const file = useRef<HTMLInputElement>(null);
  const card = useScrollThumb<HTMLFormElement>();

  const problem = slug ? slugProblem(slug) : null;
  const ready = name.trim().length >= 2 && !!slug && !problem && list.valid;
  const create = () => {
    if (!ready) return;
    const invited = list.all.filter((e) => EMAIL.test(e));
    kept.current = image;
    onCreated(addSphere({ name: name.trim(), slug, image, invited, domain: anyone ? domain : undefined }));
  };

  // the latest onClose (the panel behind re-renders often, as Oby's words stream in)
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); close.current(); } };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, []);

  return createPortal(
    <div className="modal-backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <form ref={card.list} onScroll={card.onScroll} className="modal" role="dialog" aria-modal="true" aria-labelledby="sphere-title" onSubmit={(e) => { e.preventDefault(); create(); }}>
        <header className="modal-head">
          <h2 id="sphere-title">Create an Obysphere</h2>
          <button type="button" className="icon-button" aria-label="Close" onClick={onClose}><X size={16} strokeWidth={1.6} /></button>
        </header>
        <p className="modal-lede">Where your Oby works with other people’s. You’ll be its admin.</p>

        {/* the logo beside the name: a click picks an image; its badge takes it out again */}
        <div className="sphere-form-top">
          <span className="sphere-logo">
            <button type="button" className="sphere-logo-pick" aria-label={image ? 'Change logo' : 'Add a logo'} title={image ? 'Change logo' : 'Add a logo'} onClick={() => file.current?.click()}>
              <SphereTile name={name || '?'} image={image} large />
            </button>
            {image
              ? <button type="button" className="sphere-logo-badge" aria-label="Remove logo" onClick={() => { URL.revokeObjectURL(image); setImage(undefined); }}><X size={12} strokeWidth={2} /></button>
              : <span className="sphere-logo-badge" aria-hidden="true"><ImagePlus size={12} strokeWidth={1.8} /></span>}
            <input
              ref={file}
              type="file"
              accept="image/*"
              hidden
              onChange={(e) => {
                const f = e.currentTarget.files?.[0];
                if (f) { if (image) URL.revokeObjectURL(image); setImage(URL.createObjectURL(f)); }
                e.currentTarget.value = '';
              }}
            />
          </span>
          <span className="sphere-name">
            <label className="modal-label" htmlFor="sphere-name">Name</label>
            <input id="sphere-name" className="modal-field" autoFocus maxLength={40} value={name} onChange={(e) => setName(e.target.value)} placeholder="Team or project name" autoComplete="off" spellCheck={false} />
          </span>
        </div>

        <label className="modal-label sphere-label" htmlFor="sphere-slug">Obysphere URL</label>
        <div className={`modal-field sphere-address${problem ? ' is-bad' : ''}`} onMouseDown={(e) => { if (e.target === e.currentTarget) { e.preventDefault(); e.currentTarget.querySelector('input')?.focus(); } }}>
          <input
            id="sphere-slug"
            value={slug}
            maxLength={30}
            onChange={(e) => setOwnSlug(slugOf(e.target.value))}
            onBlur={() => { if (ownSlug !== null) setOwnSlug(trimSlug(ownSlug)); }}
            autoComplete="off"
            spellCheck={false}
            aria-describedby="sphere-slug-note"
            aria-invalid={!!problem || undefined}
          />
          <span className="sphere-suffix">{SUFFIX}</span>
        </div>
        <p id="sphere-slug-note" className={`sphere-note${problem ? ' is-bad' : slug ? ' is-ok' : ''}`}>
          {problem ? (problem === 'Taken' ? `${slug}${SUFFIX} is taken` : problem)
            : slug ? <><Check size={13} strokeWidth={2} />Available</>
            : 'Letters, numbers and hyphens'}
        </p>

        <label className="modal-label sphere-label has-aside" htmlFor="sphere-emails">Invite people <span className="modal-optional">Optional</span></label>
        <EmailField list={list} id="sphere-emails" short onEnterEmpty={create} />
        {work && (
          <div className="invite-option">
            <span>Anyone with @{domain} can join</span>
            <button type="button" role="switch" aria-checked={anyone} aria-label={`Anyone with @${domain} can join`} className="set-switch" onClick={() => setAnyone(!anyone)} />
          </div>
        )}

        <div className="modal-actions">
          <button type="submit" className="modal-primary" disabled={!ready}>Create Obysphere</button>
        </div>
      </form>
      <div {...card.thumbProps} />
    </div>,
    document.body,
  );
}
