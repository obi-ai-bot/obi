import { useState } from 'react';
import { Lock, Plus } from 'lucide-react';
import { Group, Row, Select, SettingsPage, Switch, Value } from './SettingsView';
import AddSourceModal from './AddSourceModal';
import { removeSource, setTool, updateSource, useKnowledge, type Source } from './knowledge';
import { ME, useSpheres } from './spheres';

export const knowledgeLabel = 'Knowledge';

// An Obysphere's knowledge, a page of its own (Knowledge, in the side panel),
// laid out as its settings are: each source an admin connected, once, for
// everyone; adding another (AddSourceModal), under a line after them. id: which Obysphere.
export default function KnowledgeView({ id, ...frame }: {
  id: string;
  leaving: boolean;
  covered?: boolean;
  onClose: () => void;
  onGone: () => void;
}) {
  const spheres = useSpheres();
  const sphere = spheres.find((s) => s.id === id);
  const sources = useKnowledge(id);
  const [adding, setAdding] = useState(false);
  const admin = !!sphere?.admin;
  return (
    <SettingsPage title={knowledgeLabel} label={`${sphere?.name ?? ''} knowledge`} {...frame}>
      <p className="set-lede rise" style={{ '--i': 1 } as React.CSSProperties}>
        Knowledge systems every Oby in {sphere?.name}’s Obysphere has access to.
      </p>
      {sources.map((s, k) => <SourceCard key={s.id} sphere={id} source={s} admin={admin} i={2 + k * 3} />)}
      {!sources.length && (
        <Group i={2}>
          <Row label={<span className="set-none">No knowledge sources yet</span>} about={admin ? 'Connect Tetrix, or any graph or vector database with an MCP server.' : 'An admin can connect one.'} />
        </Group>
      )}
      {/* adding one is the page's, not a source's: after a line under them all */}
      {admin && (
        <div className="set-add rise" style={{ '--i': 2 + sources.length * 3 } as React.CSSProperties}>
          <button className="set-button" onClick={() => setAdding(true)}><Plus size={14} strokeWidth={1.8} />{sources.length ? 'Add another source' : 'Add knowledge source'}</button>
        </div>
      )}
      {adding && sphere && <AddSourceModal sphere={sphere.id} hasTetrix={sources.some((s) => s.kind === 'tetrix')} onClose={() => setAdding(false)} />}
    </SettingsPage>
  );
}

// One source: who connected it and to what; who can use it and when Oby does; its tools, each on or off (admin
// tools never, in a shared connection); disconnecting it, last
function SourceCard({ sphere, source: s, admin, i }: { sphere: string; source: Source; admin: boolean; i: number }) {
  const update = (patch: Partial<Source>) => updateSource(sphere, s.id, patch);
  // whose sign-in every Oby uses: yours, or whoever connected it
  const mine = s.by === ME.name;
  const whose = mine ? 'your' : `${s.by}’s`;
  return <>
    <Group i={i} title={s.name}>
      <Row label={s.kind === 'tetrix' ? `Tetrix · ${s.org}` : s.name} about={`${s.url} · connected by ${mine ? 'you' : s.by}`}>
        <Value><span className="set-dot" />Connected</Value>
      </Row>
      <Row label="Who can use it" about={s.access === 'everyone' ? `Every member’s Oby, with ${whose} sign-in` : 'Only admins’ Obys'}>
        {admin
          ? <Select value={s.access} onChange={(v) => update({ access: v as Source['access'] })} label={`Who can use ${s.name}`} options={[['everyone', 'Everyone'], ['admins', 'Admins only']]} />
          : <Value>{s.access === 'everyone' ? 'Everyone' : 'Admins only'}</Value>}
      </Row>
      <Row label="When Oby uses it" about={s.asks ? 'Oby asks you before each lookup' : 'Oby looks things up when a question needs it'}>
        {admin
          ? <Select value={s.asks ? 'ask' : 'auto'} onChange={(v) => update({ asks: v === 'ask' })} label={`When Oby uses ${s.name}`} options={[['auto', 'Automatically'], ['ask', 'Ask first']]} />
          : <Value>{s.asks ? 'Ask first' : 'Automatically'}</Value>}
      </Row>
    </Group>
    <Group i={i + 1} title="Tools" footer={`${s.name} is connected with ${whose} account, so ${s.access === 'everyone' ? 'any member’s' : 'an admin’s'} Oby can use these tools with ${mine ? 'your' : 'their'} access, except the ones turned off.`}>
      {s.tools.map((t) => (
        <Row key={t.name} label={t.name} about={t.about}>
          {t.admin
            ? <Value><Lock size={13} strokeWidth={1.8} />Off</Value>
            : admin
              ? <Switch on={t.on} onChange={(on) => setTool(sphere, s.id, t.name, on)} label={`${t.name} (${s.name})`} />
              : <Value>{t.on ? 'On' : 'Off'}</Value>}
        </Row>
      ))}
    </Group>
    {admin && (
      <Group i={i + 2}>
        <div className="set-row set-danger">
          <span className="set-label">
            Disconnect {s.name}
            <span className="set-about">Every Oby in this Obysphere stops using it. You can connect it again later.</span>
          </span>
          <button className="set-button is-danger" aria-label={`Disconnect ${s.name}`} onClick={() => removeSource(sphere, s.id)}>Disconnect</button>
        </div>
      </Group>
    )}
  </>;
}
