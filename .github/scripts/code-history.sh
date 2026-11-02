#!/usr/bin/env bash
# Keeps the code in this repo (everything but the dump.* parts) honest against
# code-history, the only branch here that keeps real history.
#
# update.yaml replaces master with a one-commit orphan on every run, so a
# hand-made change to a tracked file never shows up as a diff. That is how the
# completeness gate was lost: a reconciliation on 2026-08-03 put update.yaml
# back to its pre-#5 state and the next run carried it forward for three weeks.
#
# The rule: master's code must equal code-history's tip. A code change lands
# on BOTH branches in one atomic push ("record" below), so it is a real commit
# with a parent and a diff on code-history. A change that reached master
# without that, deliberate or not, fails "check" and the run stops before it
# ships anything.
#
#   code-history.sh check            master's code (HEAD) vs code-history
#   code-history.sh check --cached   the index vs code-history (just before
#                                    the orphan commit is made)
#   code-history.sh record           after committing a code change on master:
#                                    push it to master and code-history together
#
# CODE_HISTORY_REF names the ref to compare with (default origin/code-history);
# fetch it first.
set -euo pipefail

REF=${CODE_HISTORY_REF:-origin/code-history}
# Same set as the "Preserve the code" step in update.yaml: every path but the
# top-level dump.* parts. Without a glob magic, "*" also matches "/".
NON_DUMP=(-- ':(exclude)dump.*')

fail() {
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$1" >&2; else echo "error: $1" >&2; fi
    exit 1
}

# The non-dump tree of a commit, built from its top-level entries.
code_tree() { git ls-tree "$1" | grep -v $'\tdump\.' | git mktree; }

check() {
    local cached=()
    [ "${1:-}" = "--cached" ] && cached=(--cached)
    git rev-parse --verify -q "$REF^{commit}" >/dev/null \
        || fail "$REF not found; fetch code-history first"
    # Without --cached, compare REF with HEAD; with it, REF with the index.
    local against=(HEAD)
    [ ${#cached[@]} -gt 0 ] && against=()
    if git diff --quiet "${cached[@]}" "$REF" "${against[@]}" "${NON_DUMP[@]}"; then
        echo "Code matches $REF ($(git rev-parse --short "$REF"))."
        return 0
    fi
    echo "Code drift against $REF ($(git rev-parse --short "$REF")); '-' is code-history, '+' is what this run would ship:" >&2
    git --no-pager diff --stat "${cached[@]}" "$REF" "${against[@]}" "${NON_DUMP[@]}" >&2
    git --no-pager diff "${cached[@]}" "$REF" "${against[@]}" "${NON_DUMP[@]}" >&2
    fail "tracked non-dump files differ from code-history. If the change is intended, land it on both branches with .github/scripts/code-history.sh record (see CLAUDE.md); otherwise restore the files from code-history."
}

record() {
    local remote=${CODE_HISTORY_REMOTE:-origin}
    git fetch -q "$remote" master code-history
    local master code_history
    master=$(git rev-parse "$remote/master")
    code_history=$(git rev-parse "$remote/code-history")
    git merge-base --is-ancestor "$master" HEAD \
        || fail "HEAD is not on top of $remote/master; git reset --hard $remote/master, then redo the change (never rebase here)"
    local tree commit
    tree=$(code_tree HEAD)
    if [ "$tree" = "$(git rev-parse "$code_history^{tree}")" ]; then
        echo "code-history already has this code; pushing master only."
        git push "$remote" HEAD:refs/heads/master
        return 0
    fi
    # The code-history commit reuses the master commit's message, so its log
    # reads like the change that made it.
    commit=$(git log -1 --format=%B HEAD | git commit-tree "$tree" -p "$code_history")
    git --no-pager diff --stat "$code_history" "$commit"
    # Atomic: both refs move or neither does, so a scheduled run never sees
    # master ahead of code-history.
    git push --atomic "$remote" HEAD:refs/heads/master "$commit:refs/heads/code-history"
    echo "Recorded $(git rev-parse --short HEAD) on master and $(git rev-parse --short "$commit") on code-history."
}

case "${1:-}" in
    check) shift; check "$@" ;;
    record) record ;;
    *) echo "usage: $0 check [--cached] | record" >&2; exit 2 ;;
esac
