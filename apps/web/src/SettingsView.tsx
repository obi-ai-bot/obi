import { useEffect, useSyncExternalStore } from 'react';
import { BrandMark } from './brands';
import { useScrollThumb } from './useScrollThumb';
import { signedOut, useLive } from './live';
import { keepToken } from './api';
import { usePreview, setPreview } from './preview';
import { AGENTS, ARCHIVE_AFTER, getArchiveAfter, onArchiveAfter, setArchiveAfter } from './tasks';
import { fullness } from './Composer';
import Connectors from './ConnectorsView';
import type { Agent } from './api';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;

// Settings' pages, from Wellington's Mac app as Sangam's design has them, as far as obid serves
// them: this browser's own (General), then what obid's status says (Runner, Accounts, Models),
// read-only: changing them is the Mac app's, or obid's configuration, and Connectors (#518), what
// obid is connected to, read-only too. Remote access, Vault and About wait for their API.
const PAGES_ALL: readonly { id: string; label: string; preview?: true }[] = [
  { id: 'general', label: 'General' },
  { id: 'runner', label: 'Runner' },
  { id: 'accounts', label: 'Accounts' },
  { id: 'models', label: 'Models' },
  { id: 'connectors', label: 'Connectors' },
];
export const settingsPages = (preview: boolean) => PAGES_ALL.filter((p) => preview || !p.preview);
export const settingsLabel = (id: string) => PAGES_ALL.find((p) => p.id === id)?.label ?? 'Settings';

// How freely a job's agent works, each with its line (RunnerMode in the Mac app)
const MODES: Record<string, string> = {
  ask: 'Ask: asks before it edits a file or runs a command',
  acceptEdits: 'Accept edits: edits files without asking; asks before commands',
  plan: 'Plan: plans first, and works once you approve the plan',
  bypass: 'Bypass: asks nothing',
};

export default function SettingsView({ page, ...frame }: {
  page: string;
  leaving: boolean;
  covered?: boolean;
  onClose: () => void;
  onGone: () => void;
}) {
  const Page = PAGES[page] ?? General;
  return <SettingsPage title={settingsLabel(page)} label={`${settingsLabel(page)} settings`} {...frame}><Page /></SettingsPage>;
}

// A Settings page in the view (the app's, an Obysphere's, its Knowledge): its title over
// its groups, rising in; Esc goes back
export function SettingsPage({ title, label = title, leaving, covered = false, onClose, onGone, children }: {
  title: string;
  label?: string;  // what a screen reader calls it, when the title alone isn't enough
  leaving: boolean;
  covered?: boolean;
  onClose: () => void;
  onGone: () => void;
  children: React.ReactNode;
}) {
  const { list, onScroll, thumbProps } = useScrollThumb<HTMLElement>();

  // a timer, not animationend: animations don't run while the window is hidden
  useEffect(() => {
    if (!leaving) return;
    const t = setTimeout(onGone, LEAVE_MS);
    return () => clearTimeout(t);
  }, [leaving, onGone]);

  useEffect(() => {
    if (covered) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape' && !(e.target as Element).closest?.('input, select')) onClose(); };
    addEventListener('keydown', onKey);
    return () => removeEventListener('keydown', onKey);
  }, [onClose, covered]);

  return (
    <div className={`group-layer${leaving ? ' is-leaving' : ''}${covered ? ' is-covered' : ''}`} inert={covered}>
      <section ref={list} className="group" aria-label={label} onScroll={onScroll}>
        <div className="group-column set-column">
          <h1 className="group-title rise" style={{ '--i': 0 } as React.CSSProperties}>{title}</h1>
          {children}
        </div>
      </section>
      <div {...thumbProps} />
    </div>
  );
}

// General: this browser's own: when done tasks leave Home, the screens still being built, and
// signing this browser out of obid
function General() {
  const archiveAfter = useSyncExternalStore(onArchiveAfter, getArchiveAfter);
  const preview = usePreview();
  return <>
    <Group i={1} footer="Done tasks leave Home for Archived after this long, in this browser. Clear done on any of your apps archives them at once.">
      <Row label="Archive completed">
        <Select value={archiveAfter} onChange={setArchiveAfter} label="Archive completed" options={ARCHIVE_AFTER.map((a) => [a.id, a.label] as const)} />
      </Row>
    </Group>
    <Group i={2} footer="The Obysphere (#497) and its knowledge (#495) have no backend in obid yet. Shown, each says so and shows nothing made up.">
      <Row label="Show screens still being built"><Switch on={preview} onChange={setPreview} label="Show screens still being built" /></Row>
    </Group>
    <Group i={3} footer="This tab keeps obid's token until it closes, signs out, or obid's token changes. Other tabs ask for it again.">
      <Row label=""><SignOut className="set-button is-danger">Sign Out of This Tab</SignOut></Row>
    </Group>
  </>;
}

// Signing out: the tab forgets the token, and obid ends the session that opened the page's files
// (POST /app/sign-out), which shows its sign-in form. The dev server has no such session: the page
// asks for the token itself.
export function SignOut({ className, role, children }: { className?: string; role?: string; children: React.ReactNode }) {
  if (import.meta.env.DEV) return <button className={className} role={role} type="button" onClick={signedOut}>{children}</button>;
  return (
    <form method="post" action="sign-out" onSubmit={() => keepToken(null)}>
      <button className={className} role={role} type="submit">{children}</button>
    </form>
  );
}

// Runner: the obid this page belongs to, and how much it runs at once
function Runner() {
  const status = useLive().status;
  if (!status) return <Group i={1}><Row label={<span className="set-none">Waiting for obid…</span>} /></Group>;
  return <>
    <Group i={1} footer="This page is served by obid on this machine, at the same address as its API. The Mac app, the iPhone and this page all follow the same jobs.">
      <Row label="Runner"><Value>{status.runner.engine ?? 'runner'} {status.runner.version}</Value></Row>
      <Row label="Host"><Value>{status.runner.host}</Value></Row>
      <Row label="Running"><Value>{status.running} of {status.maxRunning} at once</Value></Row>
    </Group>
    <Group i={2} title="Permissions" footer="How much new jobs ask before they act. Each job's mode can change while it runs.">
      <Row label="Default mode"><Value>{MODES[status.permissions.mode] ?? status.permissions.mode}</Value></Row>
    </Group>
  </>;
}

// Accounts: the logins obid spreads jobs across, and how much each has used. Each signs in on the
// runner itself, through its tool's own login; this page only shows them.
function Accounts() {
  const status = useLive().status;
  const accounts = status?.accounts ?? [];
  const agents = (['claude', 'codex', 'cursor'] as Agent[]).filter((g) => accounts.some((a) => a.agent === g));
  if (!agents.length) {
    return <Group i={1} footer="Accounts are set in obid's configuration and sign in through each tool's own login on the runner."><Row label={<span className="set-none">{status ? 'No accounts' : 'Waiting for obid…'}</span>} /></Group>;
  }
  return <>{agents.map((g, k) => (
    <Group key={g} i={1 + k} title={AGENTS[g].name}>
      {accounts.filter((a) => a.agent === g).map((a) => {
        const windows = ([['5 hours', a.fiveHour], ['This week', a.sevenDay]] as const).filter(([, v]) => v != null);
        return (
          <div key={a.id} className="set-row set-usage">
            <BrandMark brand={AGENTS[g].brand} size={16} mono />
            <span className="set-label">
              {a.name}
              <span className="set-about">{[a.label, a.signedIn ? null : 'Signed out', `${a.running} running`].filter(Boolean).join(' · ')}</span>
              {windows.map(([name, v]) => (
                <span key={name} className="set-meter" role="meter" aria-valuenow={Math.round(v! * 100)} aria-valuemin={0} aria-valuemax={100} aria-label={`${name}: ${Math.round(v! * 100)}% used`}>
                  <span className={fullness(v! * 100)} style={{ width: `${Math.min(100, v! * 100)}%` }} />
                </span>
              ))}
            </span>
            <span className="set-control set-control-top">
              <span className="set-value">{windows.length ? windows.map(([name, v]) => `${name}: ${Math.round(v! * 100)}%`).join(' · ') : 'No usage reported yet'}</span>
            </span>
          </div>
        );
      })}
    </Group>
  ))}</>;
}

// Models: which model and effort new jobs use, for each tool
function Models() {
  const models = useLive().status?.models ?? {};
  const tools = (['claude', 'codex', 'cursor'] as Agent[]).filter((g) => models[g]);
  if (!tools.length) return <Group i={1}><Row label={<span className="set-none">Waiting for obid…</span>} /></Group>;
  return <Group i={1} footer="New jobs use these unless a job names its own. Oby's brain stays on Haiku: it plans and answers in the conversation, so it should be quick.">
    {tools.map((g) => {
      const m = models[g];
      return <Row key={g} label={AGENTS[g].name} about={[m.effort && `Effort ${m.effort}`, m.complexEffort && `complex jobs ${m.complexEffort}`].filter(Boolean).join(', ') || undefined}><Value>{m.model}</Value></Row>;
    })}
  </Group>;
}

const PAGES: Record<string, () => React.ReactNode> = { general: General, runner: Runner, accounts: Accounts, models: Models, connectors: Connectors };

// A titled group of rows on a card, a note under it
export function Group({ title, footer, i, children }: { title?: string; footer?: React.ReactNode; i: number; children: React.ReactNode }) {
  return (
    <section className="set-group rise" style={{ '--i': i } as React.CSSProperties}>
      {title && <h2 className="set-head">{title}</h2>}
      <div className="set-card">{children}</div>
      {footer && <p className="set-foot">{footer}</p>}
    </section>
  );
}

// One setting: its name (and a line on it) on the left, its control on the right
export function Row({ label, about, children }: { label: React.ReactNode; about?: React.ReactNode; children?: React.ReactNode }) {
  return (
    <div className="set-row">
      <span className="set-label">
        {label}
        {about && <span className="set-about">{about}</span>}
      </span>
      {children && <span className="set-control">{children}</span>}
    </div>
  );
}

export function Switch({ on, onChange, label }: { on: boolean; onChange: (on: boolean) => void; label: string }) {
  return <button role="switch" aria-checked={on} aria-label={label} className="set-switch" onClick={() => onChange(!on)} />;
}

// A pop-up menu: the system's own (a native select)
export function Select({ value, options, onChange, label }: { value: string; options: readonly (readonly [string, string])[]; onChange: (v: string) => void; label: string }) {
  return (
    <span className="set-select">
      <select value={value} onChange={(e) => onChange(e.target.value)} aria-label={label}>
        {options.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </select>
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M2.5 4 5 6.5 7.5 4" /></svg>
    </span>
  );
}

// A read-only value (like everything on a Settings page, it can be selected and copied)
export function Value({ children }: { children: React.ReactNode }) {
  return <span className="set-value">{children}</span>;
}
