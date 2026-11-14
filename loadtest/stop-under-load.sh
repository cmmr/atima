#!/bin/sh
# Stop a whole atima server, in its container, while it is busy, many
# times, and report every stop that was not clean. Run on the Docker host,
# from the repository root:
#
#   sh loadtest/stop-under-load.sh 30
#
# Each round starts a server without accounts (loadtest/compose.local.yaml,
# one worker on odd rounds and two on even ones), has simulated people and
# an AI app keep its workers busy and its queue filled, and then stops the
# container the way `docker stop` does. A clean stop exits with status 0
# within the 30 seconds Docker allows; a server that hangs is killed by
# Docker and exits with 137.

rounds="${1:-20}"
failed=0
i=0
compose="docker compose -f loadtest/compose.local.yaml"

while [ "$i" -lt "$rounds" ]; do
  i=$((i + 1))
  workers=$((1 + (i + 1) % 2))

  ATIMA_WORKERS=$workers ATIMA_MAX_CPUS=1 $compose up -d --wait atima >/dev/null 2>&1
  id="$($compose ps -q atima)"

  # Load, in the background: it is cut off when the server goes away.
  $compose run --rm -T loadtest --users 6 --minutes 2 --think 0.5 --flood 0 \
    --agents 2 --calls 8 --rounds 50 --label stop-test --out /tmp/discard >/dev/null 2>&1 &
  load=$!

  # Long enough for jobs to be running and queued; the moment varies.
  sleep $((12 + i % 7))

  begin="$(date +%s)"
  docker stop -t 30 "$id" >/dev/null
  took=$(( $(date +%s) - begin ))
  status="$(docker inspect -f '{{.State.ExitCode}}' "$id")"
  busy="$(docker logs "$id" 2>&1 | grep -c '"status":503')"

  if [ "$status" != "0" ] || [ "$took" -ge 30 ]; then
    failed=$((failed + 1))
    echo "round $i (workers=$workers): exit status $status after $took s"
    docker logs "$id" 2>&1 | tail -5 | sed 's/^/    /'
  else
    echo "round $i (workers=$workers): clean, $took s, $busy requests answered 503 on the way down"
  fi

  kill "$load" 2>/dev/null
  wait "$load" 2>/dev/null
  $compose down --volumes >/dev/null 2>&1
done

echo "$rounds rounds, $failed not clean"
[ "$failed" -eq 0 ]
