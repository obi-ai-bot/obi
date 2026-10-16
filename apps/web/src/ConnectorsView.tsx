import { useEffect, useState } from 'react';
import { Check, Link, Puzzle, Search } from 'lucide-react';
import { BrandMark } from './brands';
import { useLive } from './live';
import { Group, Row } from './SettingsView';
import { REREAD_MS, groups, list, readLists, type Connector, type Lists, type State } from './connectors';

const SAID: Record<State, string> = { connected: 'Connected', broken: 'Needs attention', unconfirmed: 'Not confirmed', available: 'Not connected' };
const NONE: Lists = { plugins: null, connections: null, problems: [] };
const rise = (i: number) => ({ '--i': i }) as React.CSSProperties;

// Settings › Connectors (#518): what obid is connected to, then what needs attention, isn't
// confirmed or is available, with a search over all of them, as Sangam's design has it
// (design/app, SettingsView.tsx). Read only: each row says where to change it. obid's plug-ins and
// connections are read when the page opens, every REREAD_MS while it's open, and again when obid
// comes back; while obid isn't answering, nothing it said before is shown as if it were current.
export default function Connectors() {
  const { status, connection } = useLive();
  const [lists, setLists] = useState<Lists | null>(null);
  const [query, setQuery] = useState('');
  const host = status?.runner.host;

  useEffect(() => {
    if (!host || connection !== 'live') { setLists(null); return; }
    let gone = false;
    const read = () => readLists(host).then((l) => { if (!gone) setLists(l); });
    read();
    const t = setInterval(read, REREAD_MS);
    return () => { gone = true; clearInterval(t); };
  }, [host, connection]);

  if (!status || connection !== 'live') {
    const later = 'What it’s connected to shows here once it answers.';
    return <Group i={1}><Row label={<span className="set-none">{connection === 'down' ? `obid isn’t answering. ${later}` : `Waiting for obid… ${later}`}</span>} /></Group>;
  }
  const all = list(status, lists ?? NONE);
  const shown = groups(all, query);
  return <>
    <label className="archive-search set-search rise" style={rise(1)}>
      <Search size={16} strokeWidth={1.6} aria-hidden="true" />
      <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search connectors" aria-label="Search connectors" />
    </label>
    {shown.map((g, k) => (
      <Group key={g.title} i={2 + k} title={g.title}>
        {g.items.map((c) => <ConnectorRow key={c.id} c={c} />)}
      </Group>
    ))}
    {!shown.length && <p className="group-empty">{all.length ? `No connector matches “${query.trim()}”` : `${status.runner.host} lists no accounts, plug-ins or connections.`}</p>}
    {lists?.problems.map((p) => <p key={p} className="set-foot set-problem rise" style={rise(2 + shown.length)} role="alert">{p}</p>)}
    <p className="set-foot rise" style={rise(2 + shown.length)}>
      {lists ? 'This page shows what obid serves, and changes none of it. ' : 'Reading obid’s plug-ins and connections… '}
      Each one says where it changes: plug-ins and connections in Oby on your Mac, where Touch ID approves a change to a connection.
    </p>
  </>;
}

function ConnectorRow({ c }: { c: Connector }) {
  return (
    <div className="set-row set-usage">
      <Mark mark={c.mark} />
      <span className="set-label">
        {c.name}
        <span className="set-about">{c.about} · {c.place}</span>
        <span className="set-about">{c.how}</span>
        <span className="set-about">{c.way}</span>
      </span>
      <span className="set-control set-control-top">
        <span className="set-value">{c.state === 'connected' && <Check size={14} strokeWidth={1.8} aria-hidden="true" />}{SAID[c.state]}</span>
      </span>
    </div>
  );
}

function Mark({ mark }: { mark: Connector['mark'] }) {
  if (mark === 'plugin') return <Puzzle size={16} strokeWidth={1.6} aria-hidden="true" />;
  if (mark === 'link') return <Link size={16} strokeWidth={1.6} aria-hidden="true" />;
  return <BrandMark brand={mark.brand} size={16} mono={mark.mono} />;
}
