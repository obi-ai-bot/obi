import { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { Check, ChevronLeft, Plug, X } from 'lucide-react';
import { BRANDS, BrandMark } from './brands';
import { Segmented, Select } from './SettingsView';
import { addSource, tetrixFor } from './knowledge';
import { ME } from './spheres';

// Adding a knowledge source to an Obysphere (its Knowledge page): first which
// kind. Tetrix: sign in to it (its own page, in a mock: a moment), then pick
// which org. Custom: any MCP server, by its name and URL and how it signs in
// (OAuth, an API key, or nothing); tested before it's added, which lists the
// tools it found. Either way, connected once, for everyone (your sign-in).
// Esc, the x or a click outside closes it.
type Step = 'pick' | 'tetrix' | 'custom';
const ORGS = [['deskree-inc', 'deskree-inc'], ['deskree', 'deskree']] as const;
// what a test of a custom server finds (a mock: a graph database's tools)
const FOUND = ['search_nodes', 'get_node', 'neighbors', 'run_query', 'similar'];

export default function AddSourceModal({ sphere, hasTetrix, onClose }: {
  sphere: string;
  hasTetrix: boolean;  // already connected: shown, but not offered again
  onClose: () => void;
}) {
  const [step, setStep] = useState<Step>('pick');
  // Tetrix: signing in (a moment), then signed in and an org picked
  const [signing, setSigning] = useState<'no' | 'busy' | 'done'>('no');
  const [org, setOrg] = useState<string>(ORGS[0][0]);
  // custom: what it's called, where, how it signs in; tested: the tools it has
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [auth, setAuth] = useState<'oauth' | 'key' | 'none'>('oauth');
  const [key, setKey] = useState('');
  const [test, setTest] = useState<'no' | 'busy' | 'ok'>('no');
  const urlOk = /^https:\/\/[^\s/]+\.[^\s]+$/.test(url.trim());
  const customReady = name.trim().length > 0 && urlOk && (auth !== 'key' || key.trim().length > 0);
  // anything changed after a test asks for a new one
  useEffect(() => setTest('no'), [url, auth, key]);

  const wait = (ms: number, then: () => void) => { const t = setTimeout(then, ms); return () => clearTimeout(t); };
  useEffect(() => (signing === 'busy' ? wait(900, () => setSigning('done')) : undefined), [signing]);
  useEffect(() => (test === 'busy' ? wait(900, () => setTest('ok')) : undefined), [test]);

  const connect = () => {
    if (step === 'tetrix' && signing === 'done') addSource(sphere, tetrixFor(org, ME.name));
    else if (step === 'custom' && test === 'ok') {
      addSource(sphere, {
        kind: 'mcp', name: name.trim(), url: url.trim(), by: ME.name, access: 'everyone', asks: false,
        tools: FOUND.map((t) => ({ name: t, about: 'Found on the server', on: true })),
      });
    } else return;
    onClose();
  };

  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopImmediatePropagation(); close.current(); } };
    addEventListener('keydown', onKey, true);
    return () => removeEventListener('keydown', onKey, true);
  }, []);

  return createPortal(
    <div className="modal-backdrop" onPointerDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <form className="modal" role="dialog" aria-modal="true" aria-labelledby="source-title" onSubmit={(e) => { e.preventDefault(); connect(); }}>
        <header className="modal-head">
          <span className="modal-head-start">
            {step !== 'pick' && <button type="button" className="icon-button" aria-label="Back" onClick={() => setStep('pick')}><ChevronLeft size={16} strokeWidth={1.6} /></button>}
            <h2 id="source-title">{step === 'tetrix' ? 'Connect Tetrix' : step === 'custom' ? 'Connect an MCP server' : 'Add knowledge source'}</h2>
          </span>
          <button type="button" className="icon-button" aria-label="Close" onClick={onClose}><X size={16} strokeWidth={1.6} /></button>
        </header>

        {step === 'pick' && (
          <div className="source-kinds">
            <button type="button" className="source-kind" disabled={hasTetrix} onClick={() => setStep('tetrix')}>
              <BrandMark brand={BRANDS.tetrix} size={20} />
              <span className="source-kind-text">Tetrix<span>{hasTetrix ? 'Already connected' : 'Your org’s code, infra and work as one graph'}</span></span>
            </button>
            <button type="button" className="source-kind" onClick={() => setStep('custom')}>
              <Plug size={20} strokeWidth={1.6} />
              <span className="source-kind-text">Custom MCP server<span>A graph or vector database with an MCP server: Neo4j, Qdrant, pgvector</span></span>
            </button>
          </div>
        )}

        {step === 'tetrix' && <>
          <p className="modal-lede">Sign in to Tetrix and pick the org. Every Oby here will look things up in it with your sign-in; its admin tools stay off.</p>
          {signing === 'done' ? <>
            <p className="source-signed"><Check size={14} strokeWidth={2} />Signed in to Tetrix as {ME.email}</p>
            <span className="modal-label sphere-label">Org</span>
            <span className="source-org"><Select value={org} onChange={setOrg} label="Org" options={ORGS} /></span>
          </> : (
            <button type="button" className="set-button source-sign" disabled={signing === 'busy'} onClick={() => setSigning('busy')}>
              <BrandMark brand={BRANDS.tetrix} size={14} />{signing === 'busy' ? 'Signing in…' : 'Sign in to Tetrix'}
            </button>
          )}
        </>}

        {step === 'custom' && <>
          <p className="modal-lede">Any knowledge base with an MCP server. Every Oby here will use it with this connection.</p>
          <label className="modal-label" htmlFor="source-name">Name</label>
          <input id="source-name" className="modal-field" autoFocus value={name} onChange={(e) => setName(e.target.value)} placeholder="Product graph" autoComplete="off" spellCheck={false} />
          <label className="modal-label sphere-label" htmlFor="source-url">MCP server URL</label>
          <input id="source-url" className="modal-field" aria-invalid={(!!url.trim() && !urlOk) || undefined} aria-describedby="source-url-note" value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://graph.example.com/mcp" autoComplete="off" spellCheck={false} />
          {url.trim() && !urlOk && <p id="source-url-note" className="sphere-note is-bad">An https:// address</p>}
          <span className="modal-label sphere-label has-aside">Sign-in
            <Segmented value={auth} onChange={(v) => setAuth(v as typeof auth)} label="Sign-in" options={[['oauth', 'OAuth'], ['key', 'API key'], ['none', 'None']]} />
          </span>
          {auth === 'key' && <input className="modal-field" type="password" value={key} onChange={(e) => setKey(e.target.value)} placeholder="API key" aria-label="API key" autoComplete="off" />}
          {auth === 'oauth' && test !== 'ok' && <p className="sphere-note">You’ll sign in to it when you test the connection.</p>}
          {test === 'ok' && (
            <div className="source-found">
              <p className="sphere-note is-ok"><Check size={13} strokeWidth={2} />Connected. Found {FOUND.length} tools</p>
              <p className="source-tools">{FOUND.map((t) => <code key={t}>{t}</code>)}</p>
            </div>
          )}
        </>}

        {step !== 'pick' && (
          <div className="modal-actions">
            {step === 'custom' && test !== 'ok' ? (
              <button type="button" className="modal-primary" disabled={!customReady || test === 'busy'} onClick={() => setTest('busy')}>{test === 'busy' ? 'Testing…' : 'Test connection'}</button>
            ) : (
              <button type="submit" className="modal-primary" disabled={step === 'tetrix' && signing !== 'done'}>Connect</button>
            )}
          </div>
        )}
      </form>
    </div>,
    document.body,
  );
}
