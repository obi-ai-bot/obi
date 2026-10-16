import { Check } from 'lucide-react';
import { BrandMark } from './brands';
import StatusDot from './StatusDot';
import { AGENTS, ASK_LABEL, ago, type Stage } from './mock';
import { answer, markSeen, type Task } from './tasks';

// A task as a card in its group: where it came from and what it is, which
// agent has it where, then what's happening now: the live step while it runs,
// the decision while it needs you; done, what it left behind. Clicking it
// (anywhere but its buttons and links) opens the task's own page.
// On that page (alone) it's the same card with everything open: the stages,
// the agent's result once it's done, the facts (repo, branch, model, what has
// to pass) and the agent's session.
export default function TaskCard({ task, alone = false, onOpen, style }: {
  task: Task;
  alone?: boolean;  // on the task's own page: everything open, nothing to fold or hover
  onOpen?: (id: string) => void;      // in the list: its page
  style?: React.CSSProperties;
}) {
  const j = task.job;
  const repo = j.repo.includes('/') ? j.repo.split('/')[1] : null;
  // top right: how long an open task has been going; when a done one finished
  const done = task.status === 'done';
  const when = done ? `${ago(j.finished ?? j.created)} ago` : ago(j.created);
  const result = done ? resultLine(task) : null;

  return (
    <article
      className={`card rise task-card is-${task.status}${alone ? ' is-open is-alone' : ''}`}
      aria-label={task.title}
      style={style}
      onClick={(e) => {
        markSeen(task.id);
        // in the list, a click opens its page; not on its buttons and links, and
        // not the end of selecting some of its text
        if (alone || (e.target as Element).closest('button, a') || !getSelection()?.isCollapsed) return;
        onOpen?.(task.id);
      }}
    >
      <header className="tc-head">
        {/* in the margin, only while it's new (blue) or needs you (orange), as in the
            side panel (not on its own page) */}
        {!alone && (task.fresh || task.status === 'needs') && <span className="tc-dots"><StatusDot task={task} /></span>}
        <BrandMark brand={task.brand} size={16} mono />
        <h2 className="tc-title">
          {task.who && <span className="tc-who">{task.who}</span>}
          {task.title}
        </h2>
        <span className="tc-ago">{when}</span>
      </header>
      <p className="tc-meta">
        {AGENTS[j.agent].name} · {j.account}{repo && <> · {repo}</>}
      </p>

      {task.status === 'running' && (
        // the step, shimmering while it works, as the stage's name does on its page
        <div className={`tc-now${j.status === 'queued' ? '' : ' is-working'}`}>
          <span className="tc-step">{j.step}</span>
          {j.round && <span className="tc-round">Round {j.round[0]} of {j.round[1]}</span>}
        </div>
      )}

      {task.status === 'needs' && j.ask && <AskBlock task={task} />}

      {/* done: what it left behind, one line; on its page, Result has it */}
      {result && <div className="tc-done"><div>{result}</div></div>}

      {/* done, the stages are in the details only */}
      {!done && <Progress stages={j.stages} />}

      {alone && <div className="tc-more">
        <div>
          {/* done: what it produced first; how it got there after */}
          {done && (j.summary || result) && (
            <Section title="Result">
              {j.summary && <p className="tc-report">{j.summary}</p>}
              {result}
            </Section>
          )}

          <Section title="Stages">
            <ol className="tc-stages">
              {j.stages.map((s) => {
                // the stage it's on pulses only while the agent works: orange while the task
                // needs you; done, it waits on someone else (a reviewer), so a plain ring
                const state: StageMark = s.state !== 'current' ? s.state : task.status === 'needs' ? 'needs' : done ? 'upcoming' : 'current';
                const detail = s.id === 'work' && j.round ? `Round ${j.round[0]} of ${j.round[1]}`
                  : s.id === 'review' && s.state === 'current' && done ? 'Waiting for review' : s.detail;
                return (
                  <li key={s.id} className={`is-${state}`}>
                    <span className="tc-stage-mark"><StageIcon state={state} /></span>
                    <span className="tc-stage-text">
                      <span className="tc-stage-title">
                        {s.title}
                        {state === 'skipped' && <span className="tc-stage-note">Skipped</span>}
                      </span>
                      {/* on its page, the live line is here instead of at the top */}
                      {state === 'current' && task.status === 'running' && <span className="tc-stage-step">{j.step}</span>}
                      {detail && <span className="tc-stage-detail">{detail}</span>}
                    </span>
                  </li>
                );
              })}
            </ol>
          </Section>

          <Section title="Details">
            <dl className="tc-facts">
              {repo && <><dt>Repository</dt><dd>{j.repo}</dd></>}
              {j.branch !== '—' && <><dt>Branch</dt><dd className="is-mono">{j.branch}</dd></>}
              {j.base !== '—' && <><dt>Base</dt><dd className="is-mono">{j.base}</dd></>}
              <dt>Model</dt><dd>{j.model}</dd>
              {j.check && <><dt>Done when</dt><dd className="is-mono">{j.check} passes</dd></>}
            </dl>
          </Section>

          {j.log && (
            <Section title="Session">
              <ul className="tc-log">
                {j.log.map((l, i) => (
                  <li key={i} className={l.tool === 'Say' ? 'is-say' : undefined}>
                    <span className="tc-tool">{l.tool !== 'Say' && l.tool}</span>
                    <span className="tc-log-text">{l.text}</span>
                    <span className="tc-ago">{ago(l.ago)}</span>
                  </li>
                ))}
              </ul>
            </Section>
          )}

        </div>
      </div>}

    </article>
  );
}

// The decision a task needs from you: what kind, Oby's headline over what
// happened, then the choices (the recommended one first-looking) and Later.
// On the card a pick shows as a check line; in the conversation it shows as
// your reply, and the block just loses its buttons.
export function AskBlock({ task, inChat = false }: { task: Task; inChat?: boolean }) {
  const ask = task.job.ask!;
  return (
    <div className="tc-ask">
      <span className={`tc-ask-kind is-${ask.kind}`}>{ASK_LABEL[ask.kind]}</span>
      <p className="tc-ask-head">{ask.headline}</p>
      <p className="tc-ask-text">{ask.text}</p>
      {ask.detail && <pre className="tc-code">{ask.detail}</pre>}
      {task.answer ? (
        !inChat && <p className="tc-answered"><Check size={14} strokeWidth={1.8} />{task.answer}</p>
      ) : (
        <div className="tc-options">
          {ask.options.map((o, i) => (
            <button
              key={o}
              className={`tc-option${i === (ask.recommended ?? 0) ? ' is-primary' : ''}${o === 'Deny' ? ' is-danger' : ''}`}
              onClick={() => answer(task.id, o)}
            >
              {o}
            </button>
          ))}
          <button className="tc-option is-quiet" onClick={() => answer(task.id, 'Later')}>Later</button>
        </div>
      )}
    </div>
  );
}

// One part of the details, under its title.
function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="tc-section">
      <h3>{title}</h3>
      {children}
    </section>
  );
}

// What a done task left behind, one line: its commits, its pull request, and
// how long it took start to finish; null when there's none of that.
export function resultLine({ job: j }: Task) {
  const took = j.finished != null ? duration(j.created - j.finished) : null;
  if (!j.commits && !j.published && !took) return null;
  return (
    <p className="tc-result">
      {[
        j.commits ? `${j.commits} commit${j.commits > 1 ? 's' : ''} on ${j.branch}` : null,
        j.published ? <a key="pr" href="#" onClick={(e) => e.preventDefault()}>{j.published.replace('deskree-inc/', '')}</a> : null,
        took ? `Took ${took}` : null,
      ].filter(Boolean).flatMap((part, i) => (i ? [' · ', part] : [part]))}
    </p>
  );
}

// minutes as "34m" or "1h 5m"
const duration = (min: number) => (min < 60 ? `${Math.max(1, Math.round(min))}m` : `${Math.floor(min / 60)}h ${Math.round(min % 60)}m`);

// the stages as one thin bar of segments along the card's foot
function Progress({ stages }: { stages: Stage[] }) {
  return (
    <div className="tc-progress" role="img" aria-label={`Stage ${stages.filter((s) => s.state === 'done').length + 1} of ${stages.length}`}>
      {stages.map((s) => <span key={s.id} className={`is-${s.state}`} />)}
    </div>
  );
}

// The same marks as wherever the task is listed (StatusDot), in a 16px spot:
// a grey dot pulsing while it's worked on, an orange dot while the task needs
// you, a grey ring still to come, a short grey dash if skipped (it didn't
// apply), a red dot if it failed;
// done, though, a filled green circle with a check, as on the Mac's job screen.
type StageMark = Stage['state'] | 'needs';
const STAGE_DOT: Record<Exclude<StageMark, 'done' | 'skipped'>, string> = {
  current: 'is-working', needs: 'is-needs', upcoming: 'is-queued', failed: 'is-failed',
};
const STAGE_LABEL: Record<StageMark, string> = {
  done: 'Done', current: 'Working', needs: 'Needs you', upcoming: 'To come', skipped: 'Skipped', failed: 'Failed',
};
function StageIcon({ state }: { state: StageMark }) {
  return (
    <span className="tc-mark" role="img" aria-label={STAGE_LABEL[state]}>
      {state === 'done' ? <span className="tc-mark-done"><Check size={9} strokeWidth={3.2} /></span>
        : state === 'skipped' ? <span className="tc-mark-skip" />
          : <span className={`status-dot ${STAGE_DOT[state]}`} />}
    </span>
  );
}
