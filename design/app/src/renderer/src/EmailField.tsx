import { useState } from 'react';
import { X } from 'lucide-react';
import { useScrollThumb } from './useScrollThumb';

// Addresses typed into one field (inviting people into an Obysphere, or into a
// new one). Each, once finished (a comma, a space or Enter after it, or a list
// pasted in), becomes a tag in the field: blue on a blue tint as an @Oby is in
// the message box, red if it isn't an email, with an x to take it out
// (Backspace in the empty field takes the last).
export const EMAIL = /^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/;
const SEPARATED = /[\s,;]+/;

export function useEmails() {
  const [emails, setEmails] = useState<string[]>([]);
  const [draft, setDraft] = useState('');
  // text into tags: split where the separators are, each address once, however it's capitalised
  const take = (text: string) => {
    const found = text.split(SEPARATED).filter(Boolean);
    const seen = (list: string[], f: string) => list.some((x) => x.toLowerCase() === f.toLowerCase());
    if (found.length) setEmails((had) => [...had, ...found.filter((f, i) => !seen(had, f) && !seen(found.slice(0, i), f))]);
    setDraft('');
  };
  // what's being typed counts too, when it's an address already
  const all = [...emails, ...(draft.trim() ? [draft.trim()] : [])];
  return { emails, setEmails, draft, setDraft, take, all, wrong: emails.filter((e) => !EMAIL.test(e)), valid: all.every((e) => EMAIL.test(e)) };
}

export default function EmailField({ list, id, inputRef, short = false, onEnterEmpty }: {
  list: ReturnType<typeof useEmails>;
  id: string;  // for its label
  inputRef?: React.Ref<HTMLInputElement>;
  short?: boolean;  // 2 rows tall to start, not 4 (where it's optional)
  onEnterEmpty?: () => void;  // Enter with nothing typed
}) {
  const { emails, setEmails, draft, setDraft, take, wrong } = list;
  const thumb = useScrollThumb<HTMLDivElement>();
  return (
    <>
      {/* a click in the field's empty room goes to the text */}
      <div
        ref={thumb.list}
        onScroll={thumb.onScroll}
        className={`invite-emails${short ? ' is-short' : ''}`}
        onMouseDown={(e) => { if (e.target === e.currentTarget) { e.preventDefault(); e.currentTarget.querySelector('input')?.focus(); } }}
      >
        {emails.map((e) => (
          <span key={e} className={`invite-email${EMAIL.test(e) ? '' : ' is-wrong'}`}>
            {e}
            <button type="button" aria-label={`Remove ${e}`} onClick={(ev) => { setEmails((had) => had.filter((x) => x !== e)); (ev.currentTarget.closest('.invite-emails')?.querySelector('input') as HTMLInputElement | null)?.focus(); }}>
              <X size={12} strokeWidth={2} />
            </button>
          </span>
        ))}
        <input
          ref={inputRef}
          id={id}
          aria-invalid={wrong.length > 0 || undefined}
          aria-describedby={wrong.length ? `${id}-wrong` : undefined}
          value={draft}
          placeholder={emails.length ? '' : 'Add emails, or paste a list'}
          spellCheck={false}
          autoComplete="off"
          onChange={(e) => (SEPARATED.test(e.target.value) ? take(e.target.value) : setDraft(e.target.value))}
          onKeyDown={(e) => {
            // Enter finishes what's typed; with nothing typed, it's the form's
            if (e.key === 'Enter') { e.preventDefault(); if (draft.trim()) take(draft); else onEnterEmpty?.(); }
            if (e.key === 'Backspace' && !draft && emails.length) setEmails((had) => had.slice(0, -1));
          }}
          onBlur={() => { if (draft.trim()) take(draft); }}
        />
      </div>
      <div {...thumb.thumbProps} />
      {wrong.length > 0 && <p id={`${id}-wrong`} className="invite-wrong">Not an email: {wrong.join(', ')}</p>}
    </>
  );
}
