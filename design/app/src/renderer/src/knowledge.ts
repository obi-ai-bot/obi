import { useSyncExternalStore } from 'react';

// What an Obysphere's Obys know beyond your own: knowledge sources, each an
// MCP server an admin connected once for everyone (one shared sign-in). Tetrix
// is the built-in one (the org's code, infra and work as one graph); anything
// else with an MCP server (a Neo4j graph, a Qdrant or pgvector store) goes in
// as a custom one.
type Tool = { name: string; about: string; admin?: boolean; on: boolean };
export type Source = {
  id: string; kind: 'tetrix' | 'mcp'; name: string; url: string;
  org?: string;  // Tetrix: which org
  by: string;  // who connected it
  access: 'everyone' | 'admins';  // whose Obys can use it
  asks: boolean;  // Oby asks before each lookup, instead of looking things up on its own
  tools: Tool[];
};

// Tetrix's tools: questions anyone's Oby can ask, then admin ones, which a
// shared connection never offers (everyone would act as the admin who connected it)
const TETRIX_TOOLS: Tool[] = [
  { name: 'Search', about: 'Find repos, services, people and work items by name', on: true },
  { name: 'Look up', about: 'Everything about one thing: owners, deploys, recent changes', on: true },
  { name: 'Query the graph', about: 'How things connect: what deploys where, who works on what', on: true },
  { name: 'Impact', about: 'What breaks if a file, service or resource changes', on: true },
  { name: 'Service map', about: 'Which services call which', on: true },
  { name: 'Cost', about: 'What the cloud bill goes on, and budgets', on: false },
  { name: 'Diagnostics', about: 'Sync health, failed runs and stale sources', admin: true, on: false },
  { name: 'Replay and purge', about: 'Re-run failed syncs, delete orphaned data', admin: true, on: false },
];
const DESKREE_TETRIX: Source = {
  id: 'tetrix', kind: 'tetrix', name: 'Tetrix', url: 'https://mcp.tetrix.dev', org: 'deskree-inc', by: 'Doti', access: 'everyone', asks: false,
  tools: TETRIX_TOOLS,
};

let bySphere: Record<string, Source[]> = { deskree: [DESKREE_TETRIX] };
const listeners = new Set<() => void>();
const set = (next: typeof bySphere) => { bySphere = next; listeners.forEach((l) => l()); };
const subscribe = (l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; };
const none: Source[] = [];
export const useKnowledge = (sphere: string) => useSyncExternalStore(subscribe, () => bySphere[sphere] ?? none);

const change = (sphere: string, fn: (list: Source[]) => Source[]) => set({ ...bySphere, [sphere]: fn(bySphere[sphere] ?? []) });
export const addSource = (sphere: string, s: Omit<Source, 'id'>) => change(sphere, (l) => [...l, { ...s, id: `k${Date.now().toString(36)}` }]);
export const updateSource = (sphere: string, id: string, patch: Partial<Source>) => change(sphere, (l) => l.map((s) => (s.id === id ? { ...s, ...patch } : s)));
export const removeSource = (sphere: string, id: string) => change(sphere, (l) => l.filter((s) => s.id !== id));
export const setTool = (sphere: string, id: string, tool: string, on: boolean) =>
  change(sphere, (l) => l.map((s) => (s.id === id ? { ...s, tools: s.tools.map((t) => (t.name === tool ? { ...t, on } : t)) } : s)));
// a newly connected Tetrix: the org picked
export const tetrixFor = (org: string, by: string): Omit<Source, 'id'> => ({ ...DESKREE_TETRIX, org, by });
