import { ApiError, api, type Account, type ConnectedApp, type Plugin, type Status } from './api';
import { BRANDS, type Brand } from './brands';
import { AGENTS } from './tasks';

// Settings › Connectors (#518): everything obid is connected to, and what's set up but not
// connected yet, as the Mac's page lists them (apps/mac/app/Connectors.swift, #498): its accounts,
// Tetrix, its GitHub login, its plug-ins and its connections. Each comes from something obid
// serves (its status, GET /v1/obid/plugins, GET /v1/connections); nothing here is a placeholder.
// The page is read only (the owner's decision on #518): changing a connection needs a device's
// signature, which a browser has no key for, so each one says where to change it.

// Whether it works, as far as obid tells. Connected is only said of what was checked.
//   connected:   signed in, and the tool or obid said so
//   broken:      set up to work, but it can't now: `how` says why
//   unconfirmed: in use, but nothing checks that it's signed in: `how` says what is known
//   available:   set up and not connected
export type State = 'connected' | 'broken' | 'unconfirmed' | 'available';

// What's drawn in front of it: a brand's mark, or a plain symbol for a plug-in or a connection
export type Mark = { brand: Brand; mono?: boolean } | 'plugin' | 'link';

export type Connector = {
  id: string;
  name: string;
  about: string;   // what it does: search reads it with the name
  place: string;   // where it is: the runner's name
  how: string;     // how it's signed in, or why it doesn't work
  state: State;
  way: string;     // how to disconnect a connected one, or connect an available one, and where
  mark: Mark;
};

// obid's plug-ins and connections, and each list it couldn't read
export type Lists = {
  plugins: Plugin[] | null;
  connections: ConnectedApp[] | null;
  // why a list couldn't be read: a timeout, a 500, a 401. Only a 404 means obid has none to list
  // (it serves no connections yet, #444); anything else is said, never shown as an empty list.
  problems: string[];
};

// How often the page reads the lists again while it's open: no event says a plug-in changed
export const REREAD_MS = 15_000;

const TETRIX_ABOUT = 'Project knowledge and blast radius';
const ON_THE_MAC = 'in Oby on your Mac, Settings › Connectors';

// obid's plug-ins and connections, as the runner called `place` lists them
export async function readLists(place: string): Promise<Lists> {
  const read = async <T,>(what: string, call: () => Promise<T>, problems: string[]): Promise<T | null> => {
    try {
      return await call();
    } catch (e) {
      if (e instanceof ApiError && e.status === 404) return null;
      problems.push(`Couldn’t read the ${what} on ${place}: ${e instanceof Error ? e.message : String(e)}`);
      return null;
    }
  };
  const pluginProblems: string[] = [], connectionProblems: string[] = [];
  const [plugins, connections] = await Promise.all([
    read('plug-ins', api.plugins, pluginProblems),
    read('connections', api.connections, connectionProblems),
  ]);
  return { plugins, connections, problems: [...pluginProblems, ...connectionProblems] };
}

// Everything obid is connected to, and what's set up but not connected yet: the coding tools'
// accounts, the plug-ins, Tetrix per account, GitHub, then the connections
export function list(status: Status, lists: Lists): Connector[] {
  const place = status.runner.host;
  return [
    ...status.accounts.map((a) => account(a, place)),
    ...(lists.plugins ?? []).map((p) => plugin(p, place)),
    ...status.accounts.flatMap((a) => tetrix(a, place) ?? []),
    ...(status.github ? [gitHub(status.github, status.checks, place)] : []),
    ...(lists.connections ?? []).map((c) => connection(c, place)),
  ];
}

// Whether every word of `query` is in its name, what it does or where it is, whatever the case or
// accents. An empty query matches every one.
export function matches(c: Connector, query: string): boolean {
  const text = fold(`${c.name} ${c.about} ${c.place}`);
  return query.split(/\s+/).filter(Boolean).every((word) => text.includes(fold(word)));
}
const fold = (text: string) => text.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();

const GROUPS: [string, State][] = [['Connected', 'connected'], ['Needs attention', 'broken'], ['Not confirmed', 'unconfirmed'], ['Available', 'available']];

// The page's groups, each in `list`'s order, with only what matches `query`; empty ones are left out
export function groups(l: Connector[], query: string): { title: string; items: Connector[] }[] {
  const shown = l.filter((c) => matches(c, query));
  return GROUPS.map(([title, state]) => ({ title, items: shown.filter((c) => c.state === state) })).filter((g) => g.items.length);
}

const tool = (a: Account) => AGENTS[a.agent]?.name ?? a.agent;
const heading = (a: Account) => `${tool(a)} · ${a.name}`;
// "Max · someone@example.com": the plan, never the email the label carries
const plan = (label: string | null) => {
  const first = label?.split(' · ')[0];
  return first && !first.includes('@') ? first : null;
};

// A coding tool's account. The tool reports the login (`label`) once it checked it; obid lists
// every account in its configuration as signed in, with none: that isn't checked.
function account(a: Account, place: string): Connector {
  const t = tool(a);
  const state: State = !a.signedIn ? 'available' : a.label ? 'connected' : 'unconfirmed';
  const how = !a.signedIn ? 'Not signed in'
    : a.label ? `Signed in with ${t}’s own login${plan(a.label) ? ` · ${plan(a.label)}` : ''}`
    : `Not checked: ${place} lists it as signed in without checking its login`;
  const way = a.signedIn
    ? `To disconnect it, take it out of the runner’s configuration on ${place}, or sign out with ${t}’s own logout in its home.`
    : `Sign it in on ${place} with ${t}’s own login, in this account’s home.`;
  const brand = AGENTS[a.agent]?.brand;
  return { id: `account-${a.id}`, name: heading(a), about: `Runs jobs in ${t}`, place, how, state, way, mark: brand ? { brand } : 'plugin' };
}

// Tetrix for one account's agents, once its tool has said whether they have it (`tetrix`): its own
// MCP login, never Oby's. An account that isn't signed in can't say, and only Claude Code and Codex
// are asked (Engine/TetrixUse.swift): Cursor's list is never read.
function tetrix(a: Account, place: string): Connector | null {
  if (!a.signedIn || !['claude', 'codex'].includes(a.agent) || a.tetrix == null) return null;
  const t = tool(a);
  return {
    id: `tetrix-${a.id}`, name: 'Tetrix', about: TETRIX_ABOUT, place,
    how: a.tetrix ? `${heading(a)}’s agents, through ${t}’s own MCP login` : `${heading(a)}’s agents aren’t signed in to it`,
    state: a.tetrix ? 'connected' : 'available',
    way: a.tetrix
      ? `To disconnect it, sign this account out of its tetrix MCP server on ${place}, with ${t}’s own login in its home.`
      : `Sign this account in to its tetrix MCP server on ${place}, with ${t}’s own login in its home.`,
    mark: { brand: BRANDS.tetrix },
  };
}

// A plug-in obid found (docs/ARCHITECTURE.md, "Plug-ins"). Ready is connected, failed needs
// attention, starting isn't confirmed yet, and off is available. Turning one on or off is the
// Mac's (PUT /v1/obid/plugins/{id}): Tetrix's needs its MCP URL first.
function plugin(p: Plugin, place: string): Connector {
  const [said, state]: [string, State] = !p.enabled ? [`Off${p.lastError ? ` · last error: ${p.lastError}` : ''}`, 'available']
    : p.state === 'ready' ? ['Ready', 'connected']
    : p.state === 'failed' ? [`Failed${p.lastError ? `: ${p.lastError}` : ', and obid didn’t say why'}`, 'broken']
    : p.state === 'starting' ? ['Starting', 'unconfirmed']
    : [`obid says “${p.state}”`, 'unconfirmed'];
  return {
    id: `plugin-${p.id}`, name: p.name, about: p.id === 'tetrix' ? TETRIX_ABOUT : aboutKinds(p.kinds), place,
    how: `A plug-in of obid’s${p.version ? ` (${p.version})` : ''} · ${said}`, state,
    way: `Turn it ${p.enabled ? 'off' : 'on'} ${ON_THE_MAC}.`,
    mark: p.id === 'tetrix' ? { brand: BRANDS.tetrix } : 'plugin',
  };
}

// What a plug-in of these kinds gives (docs/ARCHITECTURE.md 5.1)
function aboutKinds(kinds: string[]): string {
  const said = kinds.flatMap((k) => ({ context: 'context for jobs', events: 'events in your inbox', 'agent-mcp': 'tools for agents' } as Record<string, string>)[k] ?? []);
  if (!said.length) return 'A plug-in';
  const text = said.join(', ');
  return text[0].toUpperCase() + text.slice(1);
}

// The runner's own GitHub login (docs/runner-api.md, `github` in GET /v1/status). `app` is checked
// (its last token request worked); `owner` is only who the calls act as: the runner never asks gh
// whether that login is there (#517), so it isn't said to be connected.
function gitHub(github: string, checks: string | undefined, place: string): Connector {
  const app = github === 'app';
  const how = app
    ? 'Oby’s GitHub app, whose last token request worked, for the runner’s own calls. Pushing and opening pull requests use your gh login, which the runner doesn’t check.'
    : `Acts as your gh login on ${place}. The runner doesn’t check that it’s signed in.`;
  const runs = ({ ok: 'Check runs reach pull requests.', 'missing permission': 'Check runs need the app’s Checks permission.', 'no app': 'No check runs: they need the GitHub app.' } as Record<string, string>)[checks ?? ''];
  const way = app
    ? `To disconnect the app, unset OBY_GITHUB_APP_ID on ${place} and restart the runner: its calls then go as your gh login.`
    : `To disconnect it, run gh auth logout on ${place}; gh auth login signs it in again.`;
  return {
    id: 'github', name: 'GitHub', about: 'Repositories, pull requests and checks', place,
    how: runs ? `${how} ${runs}` : how, state: app ? 'connected' : 'unconfirmed', way, mark: { brand: BRANDS.github, mono: true },
  };
}

// An app or API the runner's agents use through its broker, with the secret it sends, by name.
// Without that secret in the runner's vault, every call fails: it needs attention. Disconnecting
// one needs a device's signature (docs/runner-api.md, "Connection"): the Mac's, with Touch ID.
function connection(c: ConnectedApp, place: string): Connector {
  const url = c.mcp ?? c.api ?? '';
  let host = url;
  try { host = new URL(url).host || url; } catch { /* not a URL: shown as it is */ }
  const header = c.header && c.header.toLowerCase() !== 'authorization' ? c.header : null;
  return {
    id: `connection-${c.name}`, name: c.name, about: c.mcp ? `MCP server at ${host}` : `API at ${host}`, place,
    how: c.secretSaved
      ? `The vault secret ${c.secret}, ${header ? `in the header ${header}` : 'as Authorization: Bearer'}`
      : `Its vault secret ${c.secret} is missing, so agents’ calls fail: add it to the runner’s vault on ${place}`,
    state: c.secretSaved ? 'connected' : 'broken',
    way: `To disconnect it, use Oby on your Mac, Settings › Connectors: it asks for Touch ID. A browser can’t approve it.`,
    mark: 'link',
  };
}
