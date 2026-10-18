# Live end-to-end: talking to Oby

`run.py` tests a built `obid` against the real agents: the owner's own `claude`, signed in on this Mac. It's for a person (or an agent) on the Mac, not CI: it spends real model usage, and a full run takes 10 to 25 minutes, most of it scenario 4's job.

```sh
cd core && cargo build -p obid
python3 e2e/live/run.py --obid target/debug/obid --label dev
```

What it does:

- Makes a run folder (0700) under the temp folder with obid's `home/`, `tmp/` and `config.json`: a free port on 127.0.0.1, `telemetry` false, `claudeKeychain` true, the file vault, one Claude account (`--account-dir`, the Deskree account's folder by default; never the default login), and `field/fixture-app` from `file:///Users/wellprado/Projects/Deskree/oby-field/remote.git` (`--remote`) with the check `node --test`.
- Starts `obid serve`, follows `GET /v1/events` with the token obid writes in `home/api-token`, and talks with `POST /v1/plans`.
- Runs the scenarios, prints a pass/fail table, scenario 4's job stages with their times and the load average (times on a loaded Mac aren't representative), and each failure's events and obid's log tail, with tokens redacted.
- Stops obid (its whole process group) and deletes the run folder, unless `--keep`.

| # | Scenario | Passes when |
|---|---|---|
| 1 | A question about the README | `delta`s and a `step` with a `tool` for the conversation, then Oby's `turn`, and the answer says what the README says. Skipped without the conversation harness (the binary doesn't carry "plan loop answered"). |
| 2 | A follow-up | The next turn in the same conversation repeats the codeword the first turn gave. |
| 3 | "Start a job … in bypass mode" | A `confirm` item in `GET /v1/inbox`, and no job. |
| 4 | "Start a job …" | A job with `conversation` set and its id in Oby's `turn` `jobs`; then it ends `done` within `--job-timeout` (900 s). Its stages (status, step) are timed. |
| 5 | A command that writes outside the room | The file isn't there afterwards, and with the harness, any `write` or `bash` step for it failed. The result says whether obid refused a try or the agent declined by itself. |
| 6 | Telling the finished job "also add a test" | The job goes `queued` or `running` again within 120 s (#644), and that round ends `done`. Skipped when 4's job didn't end. |
| 7 | An HTML page as an artifact | An `artifact` event for the conversation or for a job its turn started (looked for once that job ends), and its `index.html` serves with a `Content-Security-Policy` that has `default-src` and `sandbox`. Skipped when `GET /v1/artifacts` is 404. |
| 8 | An attached PNG (a red square) | The answer says red. Skipped when obid refuses the attachment. |

Scenario 4's job runs while 5, 7 and 8 talk; 6 comes last. `--only 1,2` runs some of them (6 needs 4). `--json out.json` keeps the results and events, and on a failure `out.json.obid.log`, all redacted. Exit 1 when any scenario failed.

Scenario 4's job pushes an `oby/…` branch to the field remote, as a real job would; opening its pull request fails, since `field/fixture-app` isn't on GitHub.
