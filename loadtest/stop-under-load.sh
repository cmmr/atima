#!/bin/sh
# Stop a whole atima server, in its container, while it is busy, many
# times, and report every stop that was not clean. Run on the Docker host,
# from the repository root, after building the image:
#
#   sh loadtest/stop-under-load.sh 30
#
# Each round starts a server without accounts (one worker on odd rounds,
# two on even ones), has simulated people and AI apps keep its workers busy
# and its queue filled, and then stops the container the way `docker stop`
# does. A clean stop exits with status 0 within the 30 seconds Docker
# allows; a server that hangs is killed by Docker and exits with 137.
#
# Six people acting twice a second and two apps calling eight tools at once
# are more than one or two workers can keep up with, so by the time of the
# stop jobs are running and waiting. Each round prints how many jobs had
# finished by then.

rounds="${1:-20}"
image="${ATIMA_IMAGE:-atima:local}"
# This directory, in the form Docker wants (Git Bash on Windows has `pwd -W`).
here="$(cd "$(dirname "$0")" && (pwd -W 2>/dev/null || pwd))"
failed=0
i=0

export MSYS_NO_PATHCONV=1

while [ "$i" -lt "$rounds" ]; do
  i=$((i + 1))
  workers=$((1 + (i + 1) % 2))

  docker rm -f atima-stop-server atima-stop-load >/dev/null 2>&1
  docker run -d --name atima-stop-server -e ATIMA_AUTH=none -e ATIMA_HOST=127.0.0.1 \
    -e ATIMA_WORKERS="$workers" -e ATIMA_MAX_CPUS=1 "$image" >/dev/null

  until [ "$(docker inspect -f '{{.State.Health.Status}}' atima-stop-server 2>/dev/null)" = "healthy" ]; do sleep 1; done

  # Load, from inside the server's network namespace (it listens on
  # loopback only). It is cut off when the server goes away.
  docker run -d --name atima-stop-load --network container:atima-stop-server --user 0:0 \
    -v "$here:/loadtest:ro" --entrypoint Rscript "$image" /loadtest/loadtest.R \
    --base http://127.0.0.1:8080 --mode local --users 6 --minutes 2 --think 0.5 --flood 0 \
    --agents 2 --calls 8 --rounds 50 --label stop-test --out /tmp/discard >/dev/null

  # Long enough for jobs to be running and queued; the moment varies.
  sleep $((15 + i % 7))

  begin="$(date +%s)"
  docker stop -t 30 atima-stop-server >/dev/null
  took=$(( $(date +%s) - begin ))
  status="$(docker inspect -f '{{.State.ExitCode}}' atima-stop-server)"
  served="$(docker logs atima-stop-server 2>&1 | grep -c -E '"path":"/(api/plot|mcp|api/metadata/table|api/taxonomy/table)"')"

  if [ "$status" != "0" ] || [ "$took" -ge 30 ]; then
    failed=$((failed + 1))
    echo "round $i (workers=$workers): exit status $status after $took s"
    docker logs atima-stop-server 2>&1 | tail -5 | sed 's/^/    /'
  else
    echo "round $i (workers=$workers): clean, $took s, after $served jobs"
  fi

  docker rm -f atima-stop-server atima-stop-load >/dev/null 2>&1
done

echo "$rounds rounds, $failed not clean"
[ "$failed" -eq 0 ]
