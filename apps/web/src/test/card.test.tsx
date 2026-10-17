import { renderToStaticMarkup } from 'react-dom/server';
import { describe, expect, it } from 'vitest';
import TaskCard from '../TaskCard';
import { toTask } from '../tasks';
import { item, job, state } from './fixtures';

const NOW = Date.parse('2026-10-16T10:30:00Z');

// A job's card while obid's brain waits for the owner's Confirm on something about it (#546).
describe('a task card with a confirm item', () => {
  const permission = item({ id: 'j1-permission-p1a2b3c', options: ['Allow', 'Always allow', 'Deny'] });
  const confirm = item({
    id: 'confirm-0a1b2c3d4e5f', kind: 'confirm', title: 'Always allow Bash(make lint:*) in obi-e2e/fixture-app',
    text: 'Oby’s brain planned to answer the permission with always.', options: ['Confirm', 'Cancel'], created: '2026-10-16T10:02:00Z',
    confirm: { action: 'always_allow', target: 'j1', payload: { permission: 'p1a2b3c' } },
  });
  const card = () => renderToStaticMarkup(<TaskCard task={toTask(state({ inbox: [permission, confirm] }), job({
    permission: { id: 'p1a2b3c', tool: 'Bash', title: 'Run make lint', detail: 'make lint', rule: 'Bash(make lint:*)', always: null },
  }), NOW)} />);

  it('shows the permission and the confirm side by side', () => {
    const html = card();
    expect(html.match(/class="tc-ask"/g)).toHaveLength(2);
    expect(html).toContain('>Allow</button>');
    expect(html).toContain('>Confirm it?<');
    expect(html).toContain('<p class="tc-ask-head">Always allow Bash(make lint:*) in obi-e2e/fixture-app</p>');
  });

  it('its Confirm says what it does, Cancel is there, and neither is picked for you', () => {
    const html = card();
    const confirmBlock = html.slice(html.lastIndexOf('class="tc-ask"'));
    expect(confirmBlock).toContain('>Confirm: Always allow Bash(make lint:*) in obi-e2e/fixture-app</button>');
    expect(confirmBlock).toContain('>Cancel</button>');
    expect(confirmBlock).not.toContain('is-primary');
  });
});
