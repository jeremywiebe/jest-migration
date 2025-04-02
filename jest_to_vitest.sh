#!/usr/bin/env bash

# Identifies the path that the script is in (http://stackoverflow.com/a/246128/11807)
MYPATH=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

pushd "${1:?usage: jest_to_vitest.sh <project-dir>}" || exit 1

git mc

grit apply ../jest_to_vitest.md && pnpm format
