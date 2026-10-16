import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Account, ConnectedApp, Plugin, Status } from '../api';
import { groups, list, matches, readLists, type Lists } from '../connectors';
import { state, storage } from './fixtures';

// obid's status as it sends it today (core/crates/obid/src/api.rs, `status`): accounts listed
// from its configuration with no label, and `github` "owner", `checks` "no app"
const account = (over: Partial<Account> = {}): Account => ({
  id: 'default', agent: 'claude', name: 'Default', label: null, signedIn: true, fiveHour: null, sevenDay: null,
  fiveHourResets: null, sevenDayResets: null, running: 0, tetrix: null, ...over,
});
const status = (over: Partial<Status> = {}): Status => ({ ...state().status!, runner: { version: '0.2.0', host: 'lab', engine: 'obid' }, accounts: [account()], github: 'owner', checks: 'no app', ...over });
const plugin = (over: Partial<Plugin> = {}): Plugin => ({ id: 'tetrix', name: 'Tetrix', version: '0.1.0', kinds: ['agent-mcp'], enabled: false, state: 'disabled', lastError: null, ...over });
const app = (over: Partial<ConnectedApp> = {}): ConnectedApp => ({
  name: 'mail', mcp: 'https://mcp.example.com/mcp', api: null, secret: 'mail-token', header: 'Authorization',
  created: '2026-10-11T16:02:11Z', secretSaved: true, lastUsed: null, ...over,
});
const none: Lists = { plugins: null, connections: null, problems: [] };
const byName = (l: ReturnType<typeof list>, name: string) => l.filter((c) => c.name === name);

describe('what the page lists', () => {
  it('lists obid’s accounts, and says Connected only of a login the tool reported', () => {
    const l = list(status({ accounts: [
      account({ id: 'a', name: 'Personal', label: 'Max · someone@example.com' }),
      account({ id: 'b', name: 'Work' }),
      account({ id: 'c', agent: 'codex', name: 'Team', signedIn: false }),
    ] }), none);
    const [personal] = byName(l, 'Claude Code · Personal');
    expect(personal.state).toBe('connected');
    // the plan, never the email the label carries
    expect(personal.how).toBe('Signed in with Claude Code’s own login · Max');
    expect(personal.place).toBe('lab');
    // obid lists an account until a job fails on its login: nothing checked it yet
    const [work] = byName(l, 'Claude Code · Work');
    expect(work.state).toBe('unconfirmed');
    expect(work.how).toMatch(/not checked/i);
    const [team] = byName(l, 'Codex · Team');
    expect(team.state).toBe('available');
    expect(team.how).toBe('Not signed in');
    expect(team.way).toMatch(/Codex’s own login/);
  });

  it('lists the runner’s GitHub login: the app is checked, the owner’s gh login isn’t', () => {
    const [owner] = byName(list(status(), none), 'GitHub');
    expect(owner.state).toBe('unconfirmed');
    expect(owner.how).toMatch(/gh login on lab/);
    expect(owner.how).toMatch(/No check runs/);
    expect(owner.way).toMatch(/gh auth logout/);
    const [app] = byName(list(status({ github: 'app', checks: 'ok' }), none), 'GitHub');
    expect(app.state).toBe('connected');
    expect(app.how).toMatch(/Check runs reach pull requests/);
  });

  it('lists obid’s plug-ins by what obid says of each', () => {
    const l = list(status({ accounts: [] }), { ...none, plugins: [
      plugin(),
      plugin({ id: 'ready', name: 'Ready one', kinds: ['context', 'events'], enabled: true, state: 'ready' }),
      plugin({ id: 'failed', name: 'Failed one', enabled: true, state: 'failed', lastError: 'exited with 1' }),
      plugin({ id: 'starting', name: 'Starting one', enabled: true, state: 'starting' }),
    ] });
    const [tetrix] = byName(l, 'Tetrix');
    expect(tetrix.state).toBe('available');
    expect(tetrix.about).toBe('Project knowledge and blast radius');
    expect(tetrix.how).toMatch(/Off$/);
    // read only: on and off are the Mac's
    expect(tetrix.way).toMatch(/on your Mac/);
    expect(byName(l, 'Ready one')[0].state).toBe('connected');
    expect(byName(l, 'Ready one')[0].about).toBe('Context for jobs, events in your inbox');
    expect(byName(l, 'Failed one')[0].state).toBe('broken');
    expect(byName(l, 'Failed one')[0].how).toMatch(/Failed: exited with 1/);
    expect(byName(l, 'Starting one')[0].state).toBe('unconfirmed');
  });

  it('says why a plug-in that’s off last failed, when obid says', () => {
    const [off] = list(status({ accounts: [] }), { ...none, plugins: [plugin({ state: 'failed', lastError: 'its manifest is invalid' })] });
    expect(off.state).toBe('available');
    expect(off.how).toMatch(/Off · last error: its manifest is invalid$/);
  });

  it('lists the runner’s connections; one without its secret needs attention, and each says to disconnect on the Mac', () => {
    const l = list(status({ accounts: [] }), { ...none, connections: [app(), app({ name: 'docs', mcp: null, api: 'https://api.example.com/v2', secretSaved: false, secret: 'docs-key', header: 'X-Api-Key' })] });
    const [mail] = byName(l, 'mail');
    expect(mail.state).toBe('connected');
    expect(mail.about).toBe('MCP server at mcp.example.com');
    expect(mail.how).toMatch(/as Authorization: Bearer/);
    expect(mail.way).toMatch(/on your Mac/);
    const [docs] = byName(l, 'docs');
    expect(docs.state).toBe('broken');
    expect(docs.about).toBe('API at api.example.com');
    expect(docs.how).toMatch(/docs-key is missing/);
  });

  it('lists Tetrix for an account only once its tool said', () => {
    expect(byName(list(status(), none), 'Tetrix')).toEqual([]);
    const l = list(status({ accounts: [account({ label: 'Max', tetrix: true }), account({ id: 'x', agent: 'codex', name: 'Off', label: 'Plus', tetrix: false }), account({ id: 'y', agent: 'cursor', label: 'Pro', tetrix: true })] }), none);
    expect(byName(l, 'Tetrix').map((c) => c.state)).toEqual(['connected', 'available']);
  });

  it('lists nothing that doesn’t exist', () => {
    // an older runner: no accounts, no github key, no plug-ins or connections to list
    const bare = status({ accounts: [] });
    delete bare.github;
    delete bare.checks;
    expect(list(bare, none)).toEqual([]);
    expect(list(bare, { plugins: [], connections: [], problems: [] })).toEqual([]);
    // nothing but what obid sent: one account and its GitHub login
    expect(list(status(), none).map((c) => c.name)).toEqual(['Claude Code · Default', 'GitHub']);
  });
});

describe('search', () => {
  const l = list(status({ github: 'app', accounts: [account({ label: 'Max' })] }), { ...none, plugins: [plugin({ enabled: true, state: 'ready' })], connections: [app()] });

  it('finds a connector by its name or by what it does, whatever the case or accents', () => {
    expect(l.filter((c) => matches(c, 'tetrix')).map((c) => c.name)).toEqual(['Tetrix']);
    expect(l.filter((c) => matches(c, 'blast radius')).map((c) => c.name)).toEqual(['Tetrix']);
    expect(l.filter((c) => matches(c, 'PULL requests')).map((c) => c.name)).toEqual(['GitHub']);
    expect(l.filter((c) => matches(c, 'mcp server')).map((c) => c.name)).toEqual(['mail']);
    expect(l.filter((c) => matches(c, 'gíthub')).map((c) => c.name)).toEqual(['GitHub']);
    expect(l.filter((c) => matches(c, 'runs jobs')).map((c) => c.name)).toEqual(['Claude Code · Default']);
    expect(l.filter((c) => matches(c, 'slack'))).toEqual([]);
    expect(l.filter((c) => matches(c, '  '))).toEqual(l);
  });

  it('groups what matches, Connected first, leaving out empty groups', () => {
    const broken = list(status({ accounts: [], github: undefined }), { ...none, connections: [app({ secretSaved: false })] });
    expect(groups([...l, ...broken], '').map((g) => g.title)).toEqual(['Connected', 'Needs attention']);
    expect(groups(l, 'tetrix')).toEqual([{ title: 'Connected', items: l.filter((c) => c.name === 'Tetrix') }]);
    expect(groups(l, 'nothing like it')).toEqual([]);
  });
});

describe('reading the lists', () => {
  afterEach(() => vi.unstubAllGlobals());
  const answer = (routes: Record<string, [number, unknown]>) => {
    const fetch = vi.fn(async (path: string) => {
      const [code, body] = routes[path] ?? [404, { error: 'Not found.' }];
      return new Response(JSON.stringify(body), { status: code });
    });
    vi.stubGlobal('fetch', fetch);
    vi.stubGlobal('sessionStorage', storage({ 'oby.token': 'tok-123' }));
    return fetch;
  };

  it('reads obid’s plug-ins and connections with the token', async () => {
    const fetch = answer({ '/v1/obid/plugins': [200, [plugin()]], '/v1/connections': [200, [app()]] });
    expect(await readLists('lab')).toEqual({ plugins: [plugin()], connections: [app()], problems: [] });
    expect(fetch.mock.calls.map(([path]) => path).sort()).toEqual(['/v1/connections', '/v1/obid/plugins']);
    for (const [, init] of fetch.mock.calls as unknown as [string, RequestInit][]) {
      expect((init.headers as Record<string, string>).Authorization).toBe('Bearer tok-123');
      expect(init.method).toBe('GET');
    }
  });

  it('takes a 404 as none to list: obid doesn’t serve connections yet (#444)', async () => {
    answer({ '/v1/obid/plugins': [200, []] });
    expect(await readLists('lab')).toEqual({ plugins: [], connections: null, problems: [] });
  });

  it('says why a list couldn’t be read, never showing it as empty', async () => {
    answer({ '/v1/obid/plugins': [503, { error: 'The plug-in host didn’t start.' }], '/v1/connections': [500, {}] });
    const lists = await readLists('lab');
    expect(lists.plugins).toBeNull();
    expect(lists.connections).toBeNull();
    expect(lists.problems).toEqual([
      'Couldn’t read the plug-ins on lab: The plug-in host didn’t start.',
      'Couldn’t read the connections on lab: Oby answered 500.',
    ]);
  });

  it('says so when obid isn’t answering at all', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('Failed to fetch'); }));
    const lists = await readLists('lab');
    expect(lists.problems).toHaveLength(2);
    expect(lists.problems[0]).toMatch(/Is obid running\?/);
  });
});
