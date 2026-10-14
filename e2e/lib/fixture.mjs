// The fixture repository of the end-to-end scenario (e2e/SCENARIO.md, "The fixture repository"),
// built at test time from e2e/fixtures/repo/: never a nested .git committed. Fixed author,
// committer, dates and messages, and git's user and system settings ignored, so the commit ids
// are the same on every machine and every run.

import { execFileSync } from "node:child_process";
import { cpSync, mkdirSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const FIXTURE_FILES = join(here, "..", "fixtures", "repo");

export const FIXTURE = {
  repo: "obi-e2e/fixture-app",
  baseBranch: "main",
  headBranch: "feature/average",
  // Pinned: buildFixture() must produce exactly these.
  baseSha: "aeab70f3025191d31993e778dba0eacc96c3b913",
  headSha: "6d20146f366b9fac8907b5066c30ee39aaec09b3",
  check: "node --test",
};

const AUTHOR = { name: "Obi E2E Fixture", email: "fixture@obi-e2e.invalid" };
const COMMITS = [
  { files: "base", branch: "main", message: "Initial fixture app", date: "1767225600 +0000" },
  { files: "head", branch: "feature/average", message: "Add an average helper", date: "1767229200 +0000" },
];

// git with no user or system settings (no hooks, no signing, no templates) and fixed identity.
export function git(cwd, args, date) {
  return execFileSync("git", [
    "-c", "core.autocrlf=false", "-c", "core.fileMode=false", "-c", "commit.gpgsign=false",
    "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main", ...args,
  ], {
    cwd,
    encoding: "utf8",
    env: {
      PATH: process.env.PATH,
      HOME: cwd,
      LC_ALL: "C",
      TZ: "UTC",
      GIT_CONFIG_GLOBAL: "/dev/null",
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_AUTHOR_NAME: AUTHOR.name,
      GIT_AUTHOR_EMAIL: AUTHOR.email,
      GIT_COMMITTER_NAME: AUTHOR.name,
      GIT_COMMITTER_EMAIL: AUTHOR.email,
      ...(date ? { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date } : {}),
    },
  }).trim();
}

// Builds <root>/work (a clone with both branches) and <root>/remote.git (the bare repository obid
// clones from, as file://). Returns the paths and both commit ids.
export function buildFixture(root) {
  const work = join(root, "work");
  const remote = join(root, "remote.git");
  mkdirSync(work, { recursive: true });
  // SHA-1 objects, asked for by name: the pinned ids are SHA-1, and a git whose default for new
  // repositories is SHA-256 (as Git 3.0 announces) would otherwise make other ids.
  git(work, ["init", "-q", "--template=", "--object-format=sha1", "-b", "main", "."]);
  for (const commit of COMMITS) {
    if (commit.branch !== "main") git(work, ["checkout", "-q", "-b", commit.branch]);
    const from = join(FIXTURE_FILES, commit.files);
    for (const name of readdirSync(from)) cpSync(join(from, name), join(work, name), { recursive: true });
    git(work, ["add", "-A"]);
    git(work, ["commit", "-q", "--no-verify", "-m", commit.message], commit.date);
  }
  git(root, ["clone", "-q", "--bare", "--template=", work, remote]);
  return {
    work,
    remote,
    remoteUrl: `file://${remote}`,
    baseSha: git(remote, ["rev-parse", `refs/heads/${FIXTURE.baseBranch}`]),
    headSha: git(remote, ["rev-parse", `refs/heads/${FIXTURE.headBranch}`]),
  };
}

// Every ref of a repository and what it points at: compared before and after the run to show
// nothing was pushed.
export function refs(repo) {
  return git(repo, ["for-each-ref", "--format=%(refname) %(objectname)"]);
}
