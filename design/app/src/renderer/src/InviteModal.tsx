import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, Copy, X } from 'lucide-react';
import { useScrollThumb } from './useScrollThumb';
import EmailField, { useEmails } from './EmailField';

// Inviting people into an Obysphere by email (EmailField), then Send
// invitation. Under it, the other way in: a link to pass on yourself, copied
// with the icon in its field, which can be held to the org's own email
// addresses. Send invitation, at the foot; sent, it says so and closes.
// Esc, the x or a click outside closes it.
const code = () => Math.random().toString(36).slice(2, 8);

export default function InviteModal({ sphere, domain, onSent, onClose }: {
  sphere: { name: string; url: string };
  domain?: string;  // the org's email domain: the link can be held to it
  onSent: (emails: string[]) => void;  // who was asked in
  onClose: () => void;
}) {
  const [link] = useState(() => `${sphere.url}/join/${code()}`);
  const [copied, setCopied] = useState(false);
  const [onlyDomain, setOnlyDomain] = useState(true);
  const list = useEmails();
  const [sent, setSent] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  // the app's scroll thumb, for the card (in a short window)
  const card = useScrollThumb<HTMLFormElement>();
  const ready = list.all.length > 0 && list.valid && !sent;

  // the latest onClose (the panel behind re-renders often, as Oby's words stream in)
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    input.current?.focus();
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); close.current(); } };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, []);
  useEffect(() => {
    if (!copied) return;
    const t = setTimeout(() => setCopied(false), 1600);
    return () => clearTimeout(t);
  }, [copied]);
  // sent: a moment to read it, then it closes
  useEffect(() => {
    if (!sent) return;
    const t = setTimeout(() => close.current(), 1200);
    return () => clearTimeout(t);
  }, [sent]);

  const send = () => {
    if (!ready) return;
    list.take(list.draft);
    onSent(list.all);
    setSent(true);
  };

  return createPortal(
    <div className="modal-backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <form ref={card.list} onScroll={card.onScroll} className="modal" role="dialog" aria-modal="true" aria-labelledby="invite-title" onSubmit={(e) => { e.preventDefault(); send(); }}>
        <header className="modal-head">
          <h2 id="invite-title">Invite to {sphere.name}’s Obysphere</h2>
          <button type="button" className="icon-button" aria-label="Close" onClick={onClose}><X size={16} strokeWidth={1.6} /></button>
        </header>
        <label className="modal-label" htmlFor="invite-emails">Email</label>
        <EmailField list={list} id="invite-emails" inputRef={input} onEnterEmpty={send} />

        <span className="modal-label invite-link-label">Invite link</span>
        <div className="invite-link">
          <span className="invite-url">{link}</span>
          <button
            type="button"
            className="icon-button"
            aria-label={copied ? 'Copied' : 'Copy link'}
            onClick={() => { navigator.clipboard?.writeText(`https://${link}`).then(() => setCopied(true), () => {}); }}
          >
            {copied ? <Check size={16} strokeWidth={1.8} /> : <Copy size={16} strokeWidth={1.6} />}
          </button>
        </div>
        {/* held to the org's addresses, where it has one */}
        {domain && (
          <div className="invite-option">
            <span>Only allow @{domain} emails to join</span>
            <button type="button" role="switch" aria-checked={onlyDomain} aria-label={`Only allow @${domain} emails to join with the link`} className="set-switch" onClick={() => setOnlyDomain(!onlyDomain)} />
          </div>
        )}
        <div className="modal-actions">
          <button type="submit" className="modal-primary" disabled={!ready && !sent}>
            {sent ? <><Check size={14} strokeWidth={2} />Sent</> : 'Send invitation'}
          </button>
        </div>
      </form>
      <div {...card.thumbProps} />
    </div>,
    document.body,
  );
}
