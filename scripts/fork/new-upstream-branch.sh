#!/usr/bin/env bash
# Creates a worktree cut from upstream/main for the upstream-first workflow.
#
# Usage: scripts/fork/new-upstream-branch.sh <branch>
#
# The worktree lands under .claude/worktrees/<branch> and the main checkout's
# working tree is not touched. The branch is created from upstream/main, so
# it has upstream's CLAUDE.md (no fork rules) and no fork-only content.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <branch>" >&2
  exit 1
fi

BRANCH="$1"
WORKTREE_PATH=".claude/worktrees/${BRANCH}"

# Refuse if the branch already exists (local or remote).
if git show-ref --verify --quiet "refs/heads/${BRANCH}" 2>/dev/null; then
  echo "Error: branch '${BRANCH}' already exists locally." >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}" 2>/dev/null; then
  echo "Error: branch '${BRANCH}' already exists on origin." >&2
  exit 1
fi

# Refuse if the worktree path already exists.
if [ -e "${WORKTREE_PATH}" ]; then
  echo "Error: worktree path '${WORKTREE_PATH}' already exists." >&2
  exit 1
fi

# Fetch upstream main so we cut from the latest.
git fetch upstream main

# Create the worktree. This does not touch the main checkout's working tree.
git worktree add "${WORKTREE_PATH}" -b "${BRANCH}" upstream/main

echo ""
echo "=== Reminders for this worktree ==="
echo ""
echo "1. This worktree has UPSTREAM's CLAUDE.md: no fork rules, no sdd/."
echo "   Hand the fork rules to the agent in the prompt; do not copy"
echo "   fork-only content into the upstream branch."
echo ""
echo "2. Nothing fork-only may land here: no sdd/, no fork rules in"
echo "   CLAUDE.md, no HANDOFF*.local.md / CLAUDE.local.md, no"
echo "   test/android-side-by-side commits."
echo ""
echo "3. When done, merge into fork main with a MERGE COMMIT (not a squash),"
echo "   then re-check the migration slot against the fork's highest."
