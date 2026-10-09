#!/bin/zsh
# Publishes the package to the repo's main branch: builds dist/oby from the
# working copy (dev), puts exactly those files on main, and pushes. main holds
# only the package, so whoever integrates Oby clones main and gets nothing else.
set -euo pipefail
here=${0:A:h}
root=$(git -C "$here" rev-parse --show-toplevel)
cd "$root"

[[ -z $(git status --porcelain) ]] || { echo "Commit your changes first: main is built from a commit." >&2; exit 1; }
zsh "$here/build.sh"
sha=$(git rev-parse --short HEAD)

tmp=$(mktemp -d)
trap 'git worktree remove --force "$tmp" 2>/dev/null; git branch -D publish-tmp 2>/dev/null || true' EXIT
if git ls-remote --exit-code --heads origin main >/dev/null; then
  git fetch -q origin main
  git worktree add -q -b publish-tmp "$tmp" FETCH_HEAD
else
  # first publish: main starts with no history of its own
  git worktree add -q --detach "$tmp"
  git -C "$tmp" checkout -q --orphan publish-tmp
  git -C "$tmp" rm -rqf .
fi

rsync -a --delete --exclude .git "$root/dist/oby/" "$tmp/"
git -C "$tmp" add -A
if git -C "$tmp" diff --cached --quiet; then
  echo "main is already up to date"
  exit 0
fi
git -C "$tmp" commit -q -m "Oby, built from dev $sha" ${PUBLISH_NOTE:+-m "$PUBLISH_NOTE"}
git -C "$tmp" push -q origin publish-tmp:main
echo "published dev $sha to main"
