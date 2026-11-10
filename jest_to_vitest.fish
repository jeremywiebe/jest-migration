#!/usr/bin/env fish
# Migrate a repo's Jest tests with one of this repo's GritQL patterns:
#
#   vitest         Rewrite Jest APIs to Vitest's (`jest_to_vitest_full`).
#   rstest         Rewrite Jest APIs to Rstest's (`jest_to_rstest`).
#   vitest-compat  Rewrite only module mocks, for Vitest with a `jest`
#                  compatibility layer (`jest_to_vitest_compat`).
#   rstest-compat  Rewrite only module mocks, for Rstest with a `jest`
#                  compatibility layer (`jest_to_rstest_compat`).
#
# Then it formats and lint-fixes the files it changed, and deletes the repo's
# snapshot files so the new test runner writes them afresh.

set -l usage "Usage: "(status basename)" <vitest|rstest|vitest-compat|rstest-compat> [repo-dir]"
set -l patterns (path resolve (status dirname))/.grit/patterns

if test (count $argv) -lt 1; or test (count $argv) -gt 2
    echo $usage >&2
    exit 2
end

set -l pattern
switch $argv[1]
    case vitest
        set pattern jest_to_vitest_full
    case rstest
        set pattern jest_to_rstest
    case vitest-compat
        set pattern jest_to_vitest_compat
    case rstest-compat
        set pattern jest_to_rstest_compat
    case '*'
        echo $usage >&2
        exit 2
end

set -l repo .
set -q argv[2]; and set repo $argv[2]
cd $repo; or exit 1

# The migration rewrites files in place, so start from a clean tree: then
# `git diff` shows only what the migration changed, and nothing of yours is
# overwritten.
set -l changes (git status --porcelain); or exit 1
if set -q changes[1]
    echo "Commit or stash the changes in "(pwd)" first:" >&2
    printf '%s\n' $changes >&2
    exit 1
end

grit apply $patterns/$pattern.md; or exit 1

# The patterns insert imports without regard to the repo's style or import
# order, so format and lint-fix the files they changed to put them right.
# Only those files: linting a whole repo can take minutes. Lint may still
# report problems it can't fix; those are left for a person.
set -l changed (git diff --name-only)
if set -q changed[1]
    if test -x node_modules/.bin/oxfmt
        pnpm exec oxfmt $changed; or exit 1
    else
        pnpm exec prettier --write $changed; or exit 1
    end
    if test -x node_modules/.bin/oxlint
        pnpm exec oxlint --fix $changed
    else
        pnpm exec eslint --fix $changed
    end
end

# Snapshot names and headers differ between test runners, so let the new
# runner write the snapshot files afresh instead of mixing in stale ones.
git ls-files -z -- '*.snap' | xargs -0 rm -f
