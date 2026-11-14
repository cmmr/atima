#!/bin/sh
# Stop a busy worker pool many times and report every round that does not
# finish. Run it inside the atima image, on the platform the server runs on:
#
#   docker run --rm --entrypoint sh -v "$PWD/loadtest:/loadtest:ro" atima:local \
#     /loadtest/shutdown-stress.sh 300
#
# Each round is its own R process with a time limit of 60 seconds; a round
# normally takes about three. The rounds vary the number of workers, how
# many jobs are running and queued, and how long after submitting the pool
# is stopped (including at once, before any job's code has started).
#
# Prints one line per failed round, with the round's last lines of output,
# and a count at the end. Exit status 1 if any round failed.

rounds="${1:-100}"
failed=0
i=0

while [ "$i" -lt "$rounds" ]; do
  i=$((i + 1))

  case $((i % 6)) in
    0) set -- 1 2 1    ;;   # one running, one queued (the case that hung)
    1) set -- 2 5 1    ;;   # two running, three queued
    2) set -- 2 2 0    ;;   # stopped at once, before the jobs' code runs
    3) set -- 1 3 0.2  ;;   # stopped while the first job is starting
    4) set -- 4 12 0.5 ;;   # four workers, a long queue
    5) set -- 2 1 2    ;;   # one running, one worker idle
  esac

  out="$(timeout -s KILL 60 Rscript /loadtest/shutdown-once.R "$@" 2>&1)"
  status=$?

  if [ "$status" -ne 0 ] || ! printf '%s' "$out" | grep -q " done"; then
    failed=$((failed + 1))
    echo "round $i (workers=$1 jobs=$2 pause=$3): exit status $status"
    printf '%s\n' "$out" | tail -6 | sed 's/^/    /'
    # A round that was killed leaves its worker processes behind.
    pkill -KILL -f "mirai::daemon" 2>/dev/null
  fi
done

echo "$rounds rounds, $failed failed"
[ "$failed" -eq 0 ]
