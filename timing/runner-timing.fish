#!/usr/bin/env fish
# Times a project's full test suite under Jest, Vitest and Rstest, cold: each
# run first clears that runner's own caches. The OS file cache isn't cleared
# (that needs `sudo purge`), so "cold" means the runner starts from nothing,
# not the disk.
#
# Each round runs every runner once, in a different order each round, so
# that drift during the session (heat, background load) doesn't favor one
# runner. Every run writes its log and its JSON report to the results
# folder, and a line to results.csv.
#
# Usage: runner-timing.fish [rounds] [path]
#   rounds: default 5
#   path:   only run tests under this path, for a quick check of the script
#
# RUNNER_TIMING_WORKTREES names the folder that holds the Jest, Vitest and
# Rstest worktrees.

set -l rounds 5
set -q argv[1]; and set rounds $argv[1]
set -l filter
set -q argv[2]; and set filter $argv[2]

if not set -q RUNNER_TIMING_WORKTREES
    echo "Set RUNNER_TIMING_WORKTREES to the folder of runner worktrees" >&2
    exit 1
end
set -l worktrees $RUNNER_TIMING_WORKTREES
set -l out (path resolve (status dirname))/results/(date +%Y-%m-%d-%H%M%S)
mkdir -p $out; or exit 1

# Run orders, cycled through by round: each runner goes first, middle and
# last, and each order is followed by its reverse.
set -l orders \
    "jest vitest rstest" \
    "rstest vitest jest" \
    "vitest rstest jest" \
    "jest rstest vitest" \
    "rstest jest vitest" \
    "vitest jest rstest"

function worktree_for --argument-names runner
    switch $runner
        case jest
            echo runner-comparison
        case '*'
            echo runner-comparison-$runner
    end
end

function clear_cache --argument-names runner
    switch $runner
        case jest
            pnpm exec jest --clearCache >/dev/null
        case vitest
            rm -rf node_modules/.vite node_modules/.vitest
        case rstest
            rm -rf dist/.rstest-temp node_modules/.cache
    end
end

# The command that runs a runner's suite. Each runner prints its usual
# report and writes a JSON one, so the output work is alike across runners.
function suite_command --argument-names runner json
    switch $runner
        case jest
            echo pnpm exec jest --ci --json --outputFile=$json
        case vitest
            echo pnpm exec vitest run --reporter=default --reporter=json \
                --outputFile.json=$json
        case rstest
            echo env RSTEST_JSON=$json pnpm exec rstest run
    end
end

# Prints "files,passed,failed,skipped,total" from a runner's JSON report.
function test_counts --argument-names runner json
    if not test -s $json
        echo ",,,,"
        return
    end
    node -e '
        const [runner, file] = process.argv.slice(1);
        const j = require(file);
        const row =
            runner === "rstest"
                ? [
                      j.summary.testFiles,
                      j.summary.passedTests,
                      j.summary.failedTests,
                      j.summary.skippedTests + j.summary.todoTests,
                      j.summary.tests,
                  ]
                : [
                      j.testResults.length,
                      j.numPassedTests,
                      j.numFailedTests,
                      j.numPendingTests + (j.numTodoTests ?? 0),
                      j.numTotalTests,
                  ];
        console.log(row.join(","));
    ' $runner $json
end

echo "round,runner,wall_s,user_s,sys_s,max_rss_mb,exit,files,passed,failed,skipped,total" >$out/results.csv
echo "Results: $out"

for round in (seq $rounds)
    set -l order (string split " " $orders[(math "($round - 1) % "(count $orders)" + 1")])
    for runner in $order
        pushd $worktrees/(worktree_for $runner); or exit 1
        set -l name round$round-$runner
        set -l json $out/$name.json
        set -l log $out/$name.log
        set -l timing $out/$name.time

        clear_cache $runner
        echo -n "round $round: $runner ... "
        set -l command (string split " " (suite_command $runner $json)) $filter
        # -l adds the peak memory of the largest single process.
        /usr/bin/time -l $command >$log 2>$timing
        set -l code $status

        # macOS time -l: "  12.34 real   56.78 user   9.01 sys" and
        # "  123456789  maximum resident set size" (bytes).
        set -l times (string match -r '([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys' <$timing)
        set -l rss (string match -r '(\d+)\s+maximum resident set size' <$timing)
        set -l rss_mb
        set -q rss[2]; and set rss_mb (math --scale 0 "$rss[2] / 1048576")
        set -l counts (test_counts $runner $json)

        echo "$round,$runner,$times[2],$times[3],$times[4],$rss_mb,$code,$counts" >>$out/results.csv
        echo "$times[2]s (exit $code, tests $counts)"
        popd
    end
end

echo
column -s, -t $out/results.csv
