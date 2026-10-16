import { useEffect, useState, useSyncExternalStore } from 'react';
import { Check, Search } from 'lucide-react';
import { BRANDS, BrandMark, type Brand } from './brands';
import { useScrollThumb } from './useScrollThumb';
import { AGENTS, type Agent } from './mock';

// how long the way out takes (the sink animation in app.css)
const LEAVE_MS = 220;

// Settings' pages, as Wellington's Mac app has them (apps/mac/app/Settings.swift
// on his dev branch): General (with Voice and Notifications, shared with the
// iPhone), Runner, Remote access, Accounts, Models, Vault and About; Connectors
// is ours. Each page opens in the view, as a task's page does, from the account
// menu (your picture at the icons' foot), then the side panel's Settings list.
export const SETTINGS_PAGES = [
  { id: 'general', label: 'General' },
  { id: 'runner', label: 'Runner' },
  { id: 'remote', label: 'Remote access' },
  { id: 'accounts', label: 'Accounts' },
  { id: 'models', label: 'Models' },
  { id: 'connectors', label: 'Connectors' },
  { id: 'vault', label: 'Vault' },
  { id: 'about', label: 'About' },
] as const;
export const settingsLabel = (id: string) => SETTINGS_PAGES.find((p) => p.id === id)?.label ?? 'Settings';

// What's set, kept while the app runs (a mock: nothing is saved anywhere)
const values = new Map<string, unknown>();
const listeners = new Set<() => void>();
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
function useSetting<T>(key: string, initial: T): [T, (v: T) => void] {
  const value = useSyncExternalStore(
    subscribe,
    () => (values.has(key) ? values.get(key) : initial) as T,
  );
  return [value, (v) => { values.set(key, v); listeners.forEach((l) => l()); }];
}

// How freely a job's agent works, each with its line (RunnerMode in his app)
const MODES = [
  { id: 'ask', label: 'Ask', help: 'Asks before it edits a file or runs a command' },
  { id: 'acceptEdits', label: 'Accept edits', help: 'Edits files without asking; asks before commands' },
  { id: 'plan', label: 'Plan', help: 'Plans first, and works once you approve the plan' },
  { id: 'bypass', label: 'Bypass', help: 'Asks nothing' },
];
const EFFORTS = [['low', 'Low'], ['medium', 'Medium'], ['high', 'High'], ['xhigh', 'Extra high'], ['max', 'Max']] as const;

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

// General: opening at login, how much this Mac's own jobs ask, Voice, Notifications
function General() {
  const [login, setLogin] = useSetting('login', true);
  const [mode, setMode] = useSetting('mac.mode', 'bypass');
  const [speaks, setSpeaks] = useSetting('voice.speaks', true);
  const [language, setLanguage] = useSetting('voice.language', 'system');
  return <>
    <Group i={1}>
      <Row label="Open at login"><Switch on={login} onChange={setLogin} label="Open at login" /></Row>
    </Group>
    <Group i={2} title="Permissions on this Mac" footer="How much the jobs this Mac runs itself ask. Each job’s Mode menu changes it while it runs. Always allow saves a rule, so it doesn’t ask again; remove the rule to be asked again. The runner’s jobs follow Runner › Permissions.">
      <ModeRow mode={mode} setMode={setMode} />
      <Rules id="mac.rules" initial={[
        { decision: 'Allowed', repo: 'deskree-inc/oby', rule: 'Bash(npm test:*)' },
        { decision: 'Denied', repo: 'deskree-inc/tetrix-ee', rule: 'Bash(git push --force:*)' },
      ]} />
    </Group>
    <Group i={3} title="Voice" footer="When you talk to Oby with fn, it answers out loud and, after fn + Space, listens again for your answer until you press fn or say “stop”. Typed messages are answered in writing. Pressing fn stops it mid-sentence.">
      <Row label="Speak replies to spoken requests"><Switch on={speaks} onChange={setSpeaks} label="Speak replies to spoken requests" /></Row>
      <Row label="Speech language">
        <Select value={language} onChange={setLanguage} label="Speech language" options={[['system', 'Mac language'], ['en-US', 'English'], ['pt-BR', 'Português (Brasil)'], ['pt-PT', 'Português (Portugal)']]} />
      </Row>
    </Group>
    <Group i={4} title="Notifications" footer="Oby alerts you when a job needs you: ready to publish, failed or interrupted, a question for you, out of reviews or not merged. An alert opens its job.">
      <Row label="Alerts"><Value>Allowed</Value></Row>
    </Group>
  </>;
}

// Runner: the always-on runner and how this Mac reaches it, keeping this Mac
// awake, the runner's permissions, the checks this Mac runs for it, watches,
// and the key that publishes
function Runner() {
  const [here, setHere] = useSetting('runner.here', true);
  const [url, setUrl] = useSetting('runner.url', '');
  const [awake, setAwake] = useSetting('runner.awake', true);
  const [mode, setMode] = useSetting('runner.mode', 'acceptEdits');
  const [merge, setMerge] = useSetting('checks.merge', true);
  const [apple, setApple] = useSetting('checks.apple', false);
  return <>
    <Group i={1} title="Runner" footer={here ? 'The runner is Oby’s login item on this Mac, and Oby follows it on 127.0.0.1.' : 'Oby follows the runner at this address: the island lists its jobs.'}>
      <Row label="Runner"><Segmented value={here ? 'mac' : 'remote'} onChange={(v) => setHere(v === 'mac')} options={[['mac', 'This Mac'], ['remote', 'Remote']]} label="Runner" /></Row>
      {here
        ? <Row label="Login item"><Value>On</Value></Row>
        : <Row label="URL"><TextField value={url} onChange={setUrl} placeholder="http://tetrix-lab:8790" label="Runner URL" /></Row>}
      <Row label="Status"><Value>{here || url ? <><span className="set-dot" />Connected</> : 'Off'}</Value></Row>
      <Row label="Job worktrees"><Value>3.2 GB</Value></Row>
      <Row label="Last cleanup"><Value>Today at 9:12 AM</Value></Row>
    </Group>
    <Group i={2} title="This Mac" footer="On power, Oby prevents idle sleep while This Mac is enabled and this setting is on. A running job always keeps this Mac awake.">
      <Row label="Keep my Mac available"><Switch on={awake} onChange={setAwake} label="Keep my Mac available" /></Row>
      <Row label="Availability"><Value>{awake ? 'Available, on power' : 'Sleeps when idle'}</Value></Row>
    </Group>
    <Group i={3} title="Permissions" footer="Ask: the agent asks before it edits or runs anything. Always allow saves a rule, so it doesn’t ask again; remove the rule to be asked again.">
      <ModeRow mode={mode} setMode={setMode} />
      <Rules id="runner.rules" initial={[{ decision: 'Allowed', repo: 'deskree-inc/oberon', rule: 'Bash(swift test:*)' }]} />
    </Group>
    <Group i={4} title="Checks on this Mac">
      <Row label="Run merge checks on this Mac" about="When Oby’s review approves a pull request, this Mac runs its tests and builds the Mac and iPhone apps, one at a time, before Oby merges it into dev.">
        <Switch on={merge} onChange={setMerge} label="Run merge checks on this Mac" />
      </Row>
      <Row label="Build and test agents’ work on this Mac" about="When an agent on the runner asks, this Mac builds and tests the Mac and iPhone apps at its latest commit, before Oby’s review has read it, and the agent gets the compiler’s errors and failing tests.">
        <Switch on={apple} onChange={setApple} label="Build and test agents’ work on this Mac" />
      </Row>
    </Group>
    <Group i={5} title="Apple Watch without iPhone" footer="Away from your iPhone, a paired watch reaches the runner through your Cloudflare Tunnel. Pair one in Oby’s Settings on your iPhone, with Oby open on the watch: pairing asks for Face ID.">
      <Row label={<span className="set-none">None yet</span>} />
    </Group>
    <Group i={6} title="Publishing" footer="Oby opens a pull request by itself once a job’s check passes and the secret scan is clean. When that failed, publish by hand here or on your iPhone: this Mac’s key, like the iPhone’s, signs only after Touch ID. Oby merges only into dev, once its review approves and your Mac’s checks pass.">
      <Row label="Publishing key"><Value>Registered</Value></Row>
    </Group>
  </>;
}

// Remote access: signing in to Oby's account, then reaching this Mac from anywhere
function Remote() {
  const [on, setOn] = useSetting('remote.on', true);
  const [forgot, setForgot] = useSetting('remote.forgot', false);
  return <>
    <Group i={1} title="Oby account" footer="Remote access goes through Oby’s control plane, which signs you in with a code by email and gives this Mac a hostname of its own.">
      <Row label="Signed in as"><Value>doti@deskree.com</Value></Row>
    </Group>
    <Group i={2} title="Remote access" footer="On, this Mac runs its Cloudflare Tunnel outbound, with no port to open: away from home, your iPhone reaches the gateway, and nothing else, at the hostname. Off keeps the hostname for next time. Forget removes this Mac from your account, and the hostname stops answering.">
      <Row label="Reach this Mac from anywhere"><Switch on={on && !forgot} onChange={(v) => { setOn(v); setForgot(false); }} label="Reach this Mac from anywhere" /></Row>
      {!forgot && <Row label="Hostname"><Value>doti-mbp-7f3k.oby.tetrix.pro</Value></Row>}
      <Row label="Status"><Value>{forgot ? 'Not set up' : on ? <><span className="set-dot" />Connected</> : 'Off'}</Value></Row>
      {!forgot && <Row label=""><button className="set-button is-danger" onClick={() => setForgot(true)}>Forget This Mac</button></Row>}
    </Group>
  </>;
}

// Accounts: the logins Oby spreads jobs across, who pays for each, how much each has used
export type Account = { id: string; agent: Agent; name: string; payer: string; used: number; resets: string };
// how full an account (or an agent) is: past 80% yellow, past 90% red
export const fullness = (used: number) => (used > 90 ? 'is-over' : used > 80 ? 'is-high' : '');
const ACCOUNTS: Account[] = [
  { id: 'a1', agent: 'claude', name: 'Deskree', payer: 'Deskree', used: 36, resets: 'Resets Thursday' },
  { id: 'a2', agent: 'claude', name: 'Personal', payer: 'Doti', used: 82, resets: 'Resets in 2 days' },
  { id: 'a3', agent: 'codex', name: 'Deskree', payer: 'Deskree', used: 12, resets: 'Resets Monday' },
];
// the accounts and their use this week: here, and in the message box's usage panel (the gauge)
export const useAccounts = () => useSetting<Account[]>('accounts', ACCOUNTS);
function Accounts() {
  const [accounts, setAccounts] = useAccounts();
  const [agent, setAgent] = useState<Account['agent']>('claude');
  const [name, setName] = useState('');
  const [payer, setPayer] = useState('');
  const roomiest = [...accounts].sort((a, b) => a.used - b.used)[0];
  return <>
    <Group i={1} title="Accounts on this Mac">
      <Row label={roomiest ? <span className="set-plain">Most room: {roomiest.name} on {AGENTS[roomiest.agent].name}, {100 - roomiest.used}% left this week</span> : <span className="set-none">None yet</span>} />
    </Group>
    {(['claude', 'codex', 'cursor'] as const).filter((g) => accounts.some((a) => a.agent === g)).map((g, k) => (
      <Group key={g} i={2 + k} title={AGENTS[g].name}>
        {accounts.filter((a) => a.agent === g).map((a) => (
          <div key={a.id} className="set-row set-usage">
            <BrandMark brand={AGENTS[g].brand} size={16} mono />
            <span className="set-label">
              {a.name}
              <span className="set-about">Paid by {a.payer} · {a.resets}</span>
              <span className="set-meter" role="meter" aria-valuenow={a.used} aria-valuemin={0} aria-valuemax={100} aria-label={`${a.used}% used`}>
                <span className={fullness(a.used)} style={{ width: `${a.used}%` }} />
              </span>
            </span>
            <span className="set-control set-control-top">
              <span className="set-value">{a.used}% used</span>
              <button className="set-button is-danger" onClick={() => setAccounts(accounts.filter((x) => x.id !== a.id))}>Remove</button>
            </span>
          </div>
        ))}
      </Group>
    ))}
    <Group i={5} title="Add an account">
      <Row label="Tool"><Select value={agent} onChange={(v) => setAgent(v as Account['agent'])} label="Tool" options={(Object.keys(AGENTS) as Agent[]).map((id) => [id, AGENTS[id].name] as const)} /></Row>
      <Row label="Name"><TextField value={name} onChange={setName} placeholder="Personal" label="Account name" /></Row>
      <Row label="Paid by"><TextField value={payer} onChange={setPayer} placeholder="Wellington" label="Paid by" /></Row>
      <Row label="">
        <button className="set-button" disabled={!name.trim()} onClick={() => {
          setAccounts([...accounts, { id: `a${Date.now()}`, agent, name: name.trim(), payer: payer.trim() || 'You', used: 0, resets: 'Resets in 7 days' }]);
          setName(''); setPayer('');
        }}>Add Account</button>
      </Row>
    </Group>
  </>;
}

// Models: which model and effort new jobs on this Mac use, for each tool
function Models() {
  const [claude, setClaude] = useSetting('claude.model', 'claude-opus-5-5');
  const [claudeEffort, setClaudeEffort] = useSetting('claude.effort', 'xhigh');
  const [claudeComplex, setClaudeComplex] = useSetting('claude.complexEffort', 'xhigh');
  const [codex, setCodex] = useSetting('codex.model', 'gpt-6.1-sol');
  const [codexEffort, setCodexEffort] = useSetting('codex.effort', 'high');
  const [codexComplex, setCodexComplex] = useSetting('codex.complexEffort', 'high');
  const [cursor, setCursor] = useSetting('cursor.model', 'auto');
  const codexEfforts = EFFORTS.filter(([id]) => id !== 'max');
  return <>
    <Group i={1} title="Claude Code on this Mac">
      <Row label="Model"><Select value={claude} onChange={setClaude} label="Claude Code model" options={[['claude-fable-5-1', 'Fable 5.1'], ['claude-opus-5-5', 'Opus 5.5'], ['claude-sonnet-5-5', 'Sonnet 5.5'], ['claude-haiku-5-5', 'Haiku 5.5']]} /></Row>
      <Row label="Effort"><Select value={claudeEffort} onChange={setClaudeEffort} label="Claude Code effort" options={EFFORTS} /></Row>
      <Row label="Complex job effort"><Select value={claudeComplex} onChange={setClaudeComplex} label="Claude Code complex job effort" options={EFFORTS} /></Row>
    </Group>
    <Group i={2} title="Codex on this Mac">
      <Row label="Model"><Select value={codex} onChange={setCodex} label="Codex model" options={[['gpt-6.1-sol', 'gpt-6.1-sol'], ['gpt-6-astra', 'GPT-6-Astra']]} /></Row>
      <Row label="Effort"><Select value={codexEffort} onChange={setCodexEffort} label="Codex effort" options={codexEfforts} /></Row>
      <Row label="Complex job effort"><Select value={codexComplex} onChange={setCodexComplex} label="Codex complex job effort" options={codexEfforts} /></Row>
    </Group>
    <Group i={3} title="Cursor on this Mac" footer="New jobs on this Mac use these. Oby’s brain stays on Haiku: it plans and answers in the conversation, so it should be quick.">
      <Row label="Model"><Select value={cursor} onChange={setCursor} label="Cursor model" options={[['auto', 'Auto'], ['claude-opus-5-5', 'Opus 5.5'], ['gpt-6.1-sol', 'gpt-6.1-sol']]} /></Row>
    </Group>
  </>;
}

// Vault: the secrets Oby keeps in the keychain, by name, never their values
function Vault() {
  const [names, setNames] = useSetting('vault', ['figma-token', 'sentry-dsn', 'staging-api-key']);
  const [name, setName] = useState('');
  const [value, setValue] = useState('');
  return <>
    <Group i={1} title="Secrets">
      {names.length
        ? names.map((n) => (
          <Row key={n} label={<span className="tok tok-code">{n}</span>}>
            <button className="set-button is-danger" onClick={() => setNames(names.filter((x) => x !== n))}>Remove</button>
          </Row>
        ))
        : <Row label={<span className="set-none">No secrets yet</span>} />}
    </Group>
    <Group i={2} title="Add a secret" footer="Oby uses a secret only in its own calls, for a connection you made. No agent sees it, and the secret scan stops anything outgoing that holds it, plain or encoded.">
      <Row label="Name"><TextField value={name} onChange={setName} placeholder="staging-api-key" label="Secret name" /></Row>
      <Row label="Value"><TextField value={value} onChange={setValue} placeholder="Typed once, never shown again" label="Secret value" secret /></Row>
      <Row label="">
        <button className="set-button" disabled={!name.trim() || !value} onClick={() => {
          setNames([...new Set([...names, name.trim()])].sort());
          setName(''); setValue('');
        }}>Add Secret</button>
      </Row>
    </Group>
  </>;
}

// Connectors: what's connected, then what's available, with a search over both
function Connectors() {
  const [connected, setConnected] = useSetting('connected', CONNECTORS.filter((c) => c.connected).map((c) => c.name));
  const [query, setQuery] = useState('');
  const q = query.trim().toLowerCase();
  const shown = CONNECTORS.filter((c) => !q || `${c.name} ${c.about}`.toLowerCase().includes(q));
  const groups = [
    { title: 'Connected', items: shown.filter((c) => connected.includes(c.name)) },
    { title: 'Available', items: shown.filter((c) => !connected.includes(c.name)) },
  ].filter((g) => g.items.length);
  return <>
    <label className="archive-search set-search rise" style={{ '--i': 1 } as React.CSSProperties}>
      <Search size={16} strokeWidth={1.6} />
      <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search connectors" aria-label="Search connectors" />
    </label>
    {groups.map((g, k) => (
      <Group key={g.title} i={2 + k} title={g.title}>
        {g.items.map((c) => (
          <Row key={c.name} label={<span className="set-connector"><BrandMark brand={c.brand} /><span className="set-label">{c.name}<span className="set-about">{c.about}</span></span></span>}>
            {connected.includes(c.name)
              ? <span className="set-value"><Check size={14} strokeWidth={1.8} />Connected</span>
              : <button className="set-button" onClick={() => setConnected([...connected, c.name])}>Connect</button>}
          </Row>
        ))}
      </Group>
    ))}
    {!groups.length && <p className="group-empty">No connector matches “{query.trim()}”</p>}
  </>;
}

function About() {
  const [checked, setChecked] = useState(false);
  return <>
    <Group i={1} title="Oby" footer="Oby checks for updates every 6 hours, downloads them quietly and installs them when it quits. Once one is downloaded, the island offers to restart now; if this Mac is running a check for the runner, the restart waits for it.">
      <Row label="Version"><Value>0.9.2 (412)</Value></Row>
      <Row label="">{checked ? <Value>Oby is up to date</Value> : <button className="set-button" onClick={() => setChecked(true)}>Check for Updates…</button>}</Row>
    </Group>
  </>;
}

const PAGES: Record<string, () => React.ReactNode> = { general: General, runner: Runner, remote: Remote, accounts: Accounts, models: Models, connectors: Connectors, vault: Vault, about: About };

// The services Oby reaches (placeholders until these are real)
const CONNECTORS: { name: string; about: string; brand: Brand; connected: boolean }[] = [
  { name: 'Deskree Ops', about: 'Projects, deploys and incidents', brand: BRANDS.deskree, connected: true },
  { name: 'Tetrix', about: 'Project knowledge and blast radius', brand: BRANDS.tetrix, connected: true },
  { name: 'GitHub', about: 'Repos, pull requests and checks', brand: BRANDS.github, connected: true },
  { name: 'Claude', about: 'Run jobs in Claude Code', brand: BRANDS.claude, connected: true },
  { name: 'ChatGPT', about: 'Run jobs in Codex, ask ChatGPT', brand: BRANDS.openai, connected: true },
  { name: 'Cursor', about: 'Run jobs in Cursor', brand: BRANDS.cursor, connected: false },
  { name: 'Slack', about: 'Read and send messages', brand: BRANDS.slack, connected: true },
  { name: 'Gmail', about: 'Read and manage your email', brand: BRANDS.gmail, connected: false },
  { name: 'Google Meet', about: 'Join meetings and keep the notes', brand: BRANDS.meet, connected: true },
  { name: 'Zoom', about: 'Join meetings and keep the notes', brand: BRANDS.zoom, connected: false },
];

// The default mode, with what it lets the agent do under it
function ModeRow({ mode, setMode }: { mode: string; setMode: (m: string) => void }) {
  return (
    <Row label="Default mode" about={MODES.find((m) => m.id === mode)?.help}>
      <Select value={mode} onChange={setMode} label="Default mode" options={MODES.map((m) => [m.id, m.label] as const)} />
    </Row>
  );
}

// The rules Always allow (or a deny) saved, each with Remove
type Rule = { decision: 'Allowed' | 'Denied'; repo: string; rule: string };
function Rules({ id, initial }: { id: string; initial: Rule[] }) {
  const [rules, setRules] = useSetting(id, initial);
  if (!rules.length) return <Row label={<span className="set-none">No saved rules</span>} />;
  return rules.map((r) => (
    <Row key={r.rule} label={<span className="tok tok-code">{r.rule}</span>} about={`${r.decision} · ${r.repo}`}>
      <button className="set-button is-danger" onClick={() => setRules(rules.filter((x) => x !== r))}>Remove</button>
    </Row>
  ));
}

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

export function Segmented({ value, options, onChange, label }: { value: string; options: [string, string][]; onChange: (v: string) => void; label: string }) {
  return (
    <span className="set-segmented" role="radiogroup" aria-label={label}>
      {options.map(([id, name]) => (
        <button key={id} type="button" role="radio" aria-checked={value === id} className={value === id ? 'is-on' : ''} onClick={() => onChange(id)}>{name}</button>
      ))}
    </span>
  );
}

function TextField({ value, onChange, placeholder, label, secret = false }: { value: string; onChange: (v: string) => void; placeholder: string; label: string; secret?: boolean }) {
  return <input className="set-field" type={secret ? 'password' : 'text'} value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} aria-label={label} spellCheck={false} />;
}

// A read-only value (like everything on a Settings page, it can be selected and copied)
export function Value({ children }: { children: React.ReactNode }) {
  return <span className="set-value">{children}</span>;
}
