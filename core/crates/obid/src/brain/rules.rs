//! The planner of last resort (Engine/Brain.swift, `Rules`): no model, so it only fills in what
//! it can read for sure. And the gate on what rules may do (Engine/BrainSafety.swift): they may
//! answer or ask, but never guess an action that changes the user's work.

use std::collections::BTreeSet;
use std::sync::OnceLock;

use regex::Regex;

use super::plan::{Action, Complexity, Context, Dispatch, Kind, Move, Plan, Question};
use super::planner::Planned;

/// What obid says instead of acting on a plan rules guessed on the turn's first step
/// (`BrainSafety.rulesActingRefusal`); none when the plan may go ahead.
pub fn acting_refusal(planned: &Planned, step: usize) -> Option<&'static str> {
    if step != 0 || planned.by != "rules" {
        return None;
    }
    matches!(
        planned.plan.action,
        Action::Dispatch
            | Action::StopAgent
            | Action::MoveJob
            | Action::AnswerPermission
            | Action::SetMode
    )
    .then_some("Oby couldn't think that through: say it again")
}

fn regex(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("a valid pattern"))
}

/// The plan rules make of the user's words.
pub fn plan(said: &str, context: &Context) -> Plan {
    let text = said.to_lowercase();
    if text.trim().is_empty() {
        return Plan::of(Action::Ignore, "");
    }
    // Whole words only, so "tetrix-front-end" never matches "tetrix-frontend".
    let words: BTreeSet<String> = text
        .split(|c: char| !(c.is_alphanumeric() || "-_./".contains(c)))
        .filter(|w| !w.is_empty())
        .map(str::to_owned)
        .collect();
    if let Some(moved) = move_plan(&words, context) {
        return moved;
    }
    let repos: Vec<&String> = context
        .repos
        .iter()
        .filter(|repo| {
            let lower = repo.to_lowercase();
            words.contains(&lower) || words.contains(lower.rsplit('/').next().unwrap_or(""))
        })
        .collect();
    // "auto" whenever the context offers it, so obid routes the job.
    let agent = if context.accounts.contains_key("auto") {
        Some("auto".to_owned())
    } else {
        context.accounts.keys().next().cloned()
    };
    let account = agent
        .as_ref()
        .and_then(|a| context.accounts.get(a))
        .and_then(|accounts| {
            if accounts.iter().any(|a| a == "auto") {
                Some("auto".to_owned())
            } else {
                accounts.first().cloned()
            }
        });
    let (Some(agent), Some(account), [repo]) = (agent, account, repos.as_slice()) else {
        let options: Vec<String> = if repos.len() > 1 {
            repos.iter().map(|r| (*r).clone()).collect()
        } else {
            context.repos.iter().take(3).cloned().collect()
        };
        let mut ask = Plan::of(Action::AskUser, "");
        ask.question = Some(Question {
            text: "Which repository?".into(),
            options: options
                .into_iter()
                .take(super::plan::MOST_OPTIONS)
                .collect(),
            details: None,
            recommended: None,
            plan: None,
        });
        return ask;
    };
    let repo = (*repo).clone();
    let stems: [(&str, Kind); 9] = [
        ("research", Kind::Research),
        ("compare", Kind::Research),
        ("study", Kind::Research),
        ("review", Kind::Review),
        ("fix", Kind::Fix),
        ("build", Kind::Build),
        ("test", Kind::Test),
        ("investigat", Kind::Investigate),
        ("debug", Kind::Investigate),
    ];
    let stem = stems
        .iter()
        .find(|(word, _)| text.contains(word))
        .map(|(_, kind)| *kind);
    let kind = stem.unwrap_or(Kind::Investigate);
    // "PR 12" and "pull request 12" are pull requests, "issue 42" an issue, and a bare #42 an
    // issue unless the work is a review.
    static NAMED: OnceLock<Regex> = OnceLock::new();
    static BARE: OnceLock<Regex> = OnceLock::new();
    let named = regex(&NAMED, r"\b(pr|pull request|issue)\s*#?(\d+)").captures(&text);
    let bare = regex(&BARE, r"#(\d+)")
        .captures(&text)
        .and_then(|c| c[1].parse::<i64>().ok());
    let mut pr = named
        .as_ref()
        .filter(|c| &c[1] != "issue")
        .and_then(|c| c[2].parse::<i64>().ok());
    let mut issue = named
        .as_ref()
        .filter(|c| &c[1] == "issue")
        .and_then(|c| c[2].parse::<i64>().ok());
    if named.is_none()
        && let Some(bare) = bare
    {
        if kind == Kind::Review {
            pr = Some(bare);
        } else {
            issue = Some(bare);
        }
    }
    let keep_going = text.contains("until") || text.contains("keep going") || text.contains("loop");
    let name = repo.rsplit('/').next().unwrap_or(&repo).to_owned();
    let job = |pr: Option<i64>, issue: Option<i64>, epic: Option<i64>| Dispatch {
        agent: agent.clone(),
        account: account.clone(),
        repo: repo.clone(),
        base_branch: None,
        pr,
        issue,
        epic,
        kind,
        title: None,
        task: said.to_owned(),
        inputs: vec![],
        rounds: if keep_going { 5 } else { 1 },
        check: None,
        complexity: if epic.is_none() {
            Complexity::Routine
        } else {
            Complexity::Complex
        },
        start_when: None,
        mode: None,
        reads: None,
    };
    let dispatch = |reply: String, dispatches: Vec<Dispatch>| {
        let mut plan = Plan::of(Action::Dispatch, &reply);
        plan.dispatches = dispatches;
        plan
    };
    static EPIC: OnceLock<Regex> = OnceLock::new();
    if let Some(epic) = regex(&EPIC, r"\bepic\s*#?(\d+)")
        .captures(&text)
        .and_then(|c| c[1].parse::<i64>().ok())
    {
        return dispatch(
            format!("Oby will work on epic #{epic} in {name}, one job per open sub-issue."),
            vec![job(None, None, Some(epic))],
        );
    }
    // "Finish #19 from PR #124": the issue's work, started from the pull request's head (#219). A
    // review or an investigation the user asked for stays one, of the pull request or the issue.
    static FROM: OnceLock<Regex> = OnceLock::new();
    static BEFORE: OnceLock<Regex> = OnceLock::new();
    if let Some(from) = regex(&FROM, r"\bfrom\s+(?:pr|pull request)\s*#?(\d+)").captures(&text)
        && let Ok(pr) = from[1].parse::<i64>()
        && let Some(issue) = regex(&BEFORE, r"(?:\bissue\s*#?|#)(\d+)")
            .captures(&text[..from.get(0).map_or(0, |m| m.start())])
            .and_then(|c| c[1].parse::<i64>().ok())
    {
        return match stem {
            Some(Kind::Review) => dispatch(
                format!("Review in {name}, PR #{pr}."),
                vec![job(Some(pr), None, None)],
            ),
            Some(Kind::Investigate) => dispatch(
                format!("Investigate in {name}, issue #{issue}."),
                vec![job(None, Some(issue), None)],
            ),
            _ => {
                let mut finish = job(Some(pr), Some(issue), None);
                finish.kind = stem.unwrap_or(Kind::Fix);
                dispatch(
                    format!(
                        "{} in {name}, issue #{issue} from PR #{pr}.",
                        capitalized(finish.kind.as_str())
                    ),
                    vec![finish],
                )
            }
        };
    }
    // Several numbers ("#12, #15 and #18") are one job each: pull requests for a review, issues
    // otherwise.
    let mut numbers: Vec<i64> = vec![];
    for found in regex(&BARE, r"#(\d+)").captures_iter(&text) {
        if let Ok(n) = found[1].parse::<i64>()
            && !numbers.contains(&n)
        {
            numbers.push(n);
        }
    }
    if numbers.len() > 1 {
        let jobs: Vec<Dispatch> = numbers
            .iter()
            .take(10)
            .map(|n| {
                if kind == Kind::Review {
                    job(Some(*n), None, None)
                } else {
                    job(None, Some(*n), None)
                }
            })
            .collect();
        return dispatch(
            format!(
                "Oby will {} {} {} in {name}.",
                kind.as_str(),
                jobs.len(),
                if kind == Kind::Review {
                    "pull requests"
                } else {
                    "issues"
                }
            ),
            jobs,
        );
    }
    let number = pr
        .map(|pr| format!(", PR #{pr}"))
        .or_else(|| issue.map(|issue| format!(", issue #{issue}")))
        .unwrap_or_default();
    dispatch(
        format!("{} in {name}{number}.", capitalized(kind.as_str())),
        vec![job(pr, issue, None)],
    )
}

fn capitalized(word: &str) -> String {
    let mut chars = word.chars();
    chars.next().map_or(String::new(), |first| {
        first.to_uppercase().chain(chars).collect()
    })
}

/// "Move it to Codex", "switch that one to Fable": a move to a tool or model the words name, of
/// the only job there is. With several jobs, rules can't tell which one, so they say so.
fn move_plan(words: &BTreeSet<String>, context: &Context) -> Option<Plan> {
    if !words.contains("move") && !words.contains("switch") {
        return None;
    }
    let models = [
        ("fable", "claude-fable-5-1"),
        ("opus", "claude-opus-5-5"),
        ("sonnet", "claude-sonnet-5-5"),
        ("haiku", "claude-haiku-5-5"),
        ("astra", "gpt-6-astra"),
    ];
    let model = models
        .iter()
        .find(|(word, _)| words.contains(*word))
        .map(|(_, id)| *id);
    let agent = ["codex", "claude", "cursor"]
        .into_iter()
        .find(|tool| words.contains(*tool));
    if model.is_none() && agent.is_none() {
        return None;
    }
    if context.movable.len() != 1 {
        return Some(Plan::of(
            Action::ReplyOnly,
            "Oby couldn't tell which job to move. Say it again in a moment.",
        ));
    }
    let mut plan = Plan::of(Action::MoveJob, "");
    plan.jobs = Some(context.movable.clone());
    plan.destination = Some(Move {
        // A model names its tool: Claude Code's start with "claude-".
        agent: model
            .map(|m| {
                if m.starts_with("claude-") {
                    "claude"
                } else {
                    "codex"
                }
            })
            .or(agent)
            .unwrap_or("auto")
            .to_owned(),
        account: "auto".into(),
        model: model.unwrap_or("auto").to_owned(),
    });
    Some(plan)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn context() -> Context {
        Context {
            accounts: BTreeMap::from([
                ("auto".into(), vec!["auto".into(), "Personal".into()]),
                ("claude".into(), vec!["auto".into(), "Personal".into()]),
            ]),
            repos: vec![
                "deskree-inc/oby".into(),
                "deskree-inc/tetrix-front-end".into(),
            ],
            ..Context::default()
        }
    }

    /// BrainSteadyTests.rulesCannotActOnTheFirstStep
    #[test]
    fn rules_cannot_act_on_the_first_step() {
        let planned = Planned {
            plan: Plan::of(Action::Dispatch, ""),
            by: "rules".into(),
            refused: vec![],
        };
        assert_eq!(
            acting_refusal(&planned, 0),
            Some("Oby couldn't think that through: say it again")
        );
        assert_eq!(acting_refusal(&planned, 1), None);
        let mut question = Plan::of(Action::AskUser, "");
        question.question = Some(Question {
            text: "Which repository?".into(),
            options: vec![],
            details: None,
            recommended: None,
            plan: None,
        });
        let asked = Planned {
            plan: question,
            by: "rules".into(),
            refused: vec![],
        };
        assert_eq!(acting_refusal(&asked, 0), None);
        let brain = Planned {
            by: "claude".into(),
            ..planned
        };
        assert_eq!(acting_refusal(&brain, 0), None);
    }

    /// FinishFromPRTests.rulesDispatchTheIssueFromThePullRequestsHead, and
    /// theBrainsPlanIsDispatchedFromThePullRequestsHead's record line.
    #[test]
    fn rules_dispatch_the_issue_from_the_pull_requests_head() {
        let context = context();
        let shape = |said: &str| {
            let plan = plan(said, &context);
            assert!(plan.problems(&context, "zq9").is_empty(), "{said}");
            plan.dispatches
                .iter()
                .map(|d| {
                    format!(
                        "{} {}/{}",
                        d.kind.as_str(),
                        d.issue.unwrap_or(0),
                        d.pr.unwrap_or(0)
                    )
                })
                .collect::<Vec<_>>()
        };
        assert_eq!(shape("finish oby #19 from PR #124"), ["fix 19/124"]);
        assert_eq!(
            shape("pick up issue 19 in oby from pull request 124"),
            ["fix 19/124"]
        );
        assert_eq!(shape("build oby #19 from PR #124"), ["build 19/124"]);
        assert_eq!(shape("review oby #19 from PR #124"), ["review 0/124"]);
        assert_eq!(
            shape("investigate oby #19 from PR #124"),
            ["investigate 19/0"]
        );
        let planned = Planned {
            plan: plan("finish oby #19 from PR #124", &context),
            by: "claude".into(),
            refused: vec![],
        };
        let line =
            super::super::planner::Record::new("finish oby #19 from PR #124", &planned).line();
        assert!(
            line.contains("fix deskree-inc/oby #19 from PR #124"),
            "{line}"
        );
    }

    #[test]
    fn rules_read_only_what_they_can_be_sure_of() {
        let context = context();
        let fix = plan("fix oby #12, #15 and #18", &context);
        assert_eq!(fix.action, Action::Dispatch);
        assert_eq!(fix.reply, "Oby will fix 3 issues in oby.");
        assert_eq!(
            fix.dispatches.iter().map(|d| d.issue).collect::<Vec<_>>(),
            [Some(12), Some(15), Some(18)]
        );
        assert!(fix.problems(&context, "zq9").is_empty());
        let review = plan("review oby PR 33", &context);
        assert_eq!(review.reply, "Review in oby, PR #33.");
        let finish = plan("finish oby #19 from PR #124", &context);
        assert_eq!(finish.reply, "Fix in oby, issue #19 from PR #124.");
        assert_eq!(finish.dispatches[0].pr, Some(124));
        // A name that's only part of a repository's isn't it.
        let unclear = plan("review tetrix-frontend #2", &context);
        assert_eq!(unclear.action, Action::AskUser);
        assert_eq!(unclear.question.unwrap().text, "Which repository?");
        assert_eq!(plan("  ", &context).action, Action::Ignore);
        let mut one = context.clone();
        one.movable = vec!["ab12cd34".into()];
        let moved = plan("move it to fable", &one);
        assert_eq!(moved.action, Action::MoveJob);
        assert_eq!(
            moved.destination.unwrap(),
            Move {
                agent: "claude".into(),
                account: "auto".into(),
                model: "claude-fable-5-1".into()
            }
        );
        assert_eq!(
            plan("move it to codex", &context).reply,
            "Oby couldn't tell which job to move. Say it again in a moment."
        );
    }
}
