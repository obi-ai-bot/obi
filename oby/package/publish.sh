#!/bin/zsh
# Publishes the package to the repo's main branch: builds dist/oby from the
# working copy (dev), puts exactly those files on main, and pushes. main holds
# only the package, so whoever integrates Oby clones main and gets nothing else.
set -euo pipefail
here=${0:A:h}
root=$(git -C "$here" rev-parse --show-toplevel)
cd "$root"

[[ $(git branch --show-current) == dev ]] || { echo "Publish from dev: main is built from it." >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first: main is built from a commit." >&2; exit 1; }
zsh "$here/build.sh"
sha=$(git rev-parse --short HEAD)

tmp=$(mktemp -d)
trap '{ git worktree remove --force "$tmp"; rm -rf "$tmp"; git branch -D publish-tmp; } >/dev/null 2>&1 || true' EXIT
git worktree prune
set +e; git ls-remote --exit-code --heads origin main >/dev/null; remote=$?; set -e
if (( remote == 0 )); then
  git fetch -q origin main
  git worktree add -q --detach "$tmp" FETCH_HEAD
elif (( remote == 2 )); then
  # first publish: main starts with no history of its own
  git worktree add -q --detach "$tmp"
  git -C "$tmp" checkout -q --orphan publish-tmp
  git -C "$tmp" rm -rqf .
else
  echo "Couldn't reach origin." >&2; exit 1
fi

rsync -a --delete --exclude .git "$root/dist/oby/" "$tmp/"
git -C "$tmp" add -A
if git -C "$tmp" diff --cached --quiet; then
  echo "main is already up to date"
  exit 0
fi
msg=(-m "Oby, built from dev $sha")
[[ -n ${PUBLISH_NOTE:-} ]] && msg+=(-m "$PUBLISH_NOTE")
git -C "$tmp" commit -q "${msg[@]}"
git -C "$tmp" push -q origin HEAD:main
echo "published dev $sha to main"
