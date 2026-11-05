#!/usr/bin/env bash

pushd "${1:?usage: jest_to_vitest.sh <project-dir>}" || exit 1

# Reset world
git mc

# Apply Grit transforms
grit apply "$HOME/src/jest_to_vitest/.grit/patterns/jest_to_vitest.md" && pnpm format && pnpm lint --fix

# Delete snapshots because Vitest can regenerate them and that gives us a
# cleaner diff (instead of leaving stale Jest snapshots because the "titling"
# doesn't match).
git ls-files | grep '.*\.snap' | xargs rm -rf

pnpm install
pnpm test -u # update snapshots
