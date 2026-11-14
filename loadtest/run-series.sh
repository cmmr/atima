#!/bin/sh
# The whole load test, at several worker counts, against the container
# stack on this machine. Run on the Docker host, from the repository root,
# after building the images (`docker compose build` in deploy/):
#
#   sh loadtest/run-series.sh "1 2 4" "10 30"
#
# The first argument is the worker counts to try, the second the numbers of
# simulated people. For each pair a new, empty server is started (shared
# mode, behind Caddy, with the mock sign-in provider answering after
# MOCK_DELAY seconds, default 2), the test runs, and the server and its data
# are removed. Then, for each worker count, a server without accounts is
# started for the AI-app part. Results go to loadtest/results/.
#
# THINK is the mean number of seconds between one person's actions (default
# 5, which is someone clicking without pause; 20 is closer to someone who
# looks at each figure). AGENTS=0 leaves out the AI-app part.
#
# Each job gets one CPU core (ATIMA_MAX_CPUS=1), so that the worker count is
# the only thing that changes between runs.

workers_list="${1:-1 2 4}"
users_list="${2:-10 30}"
minutes="${MINUTES:-3}"
think="${THINK:-5}"
note="${NOTE:-}"

export MOCK_DELAY="${MOCK_DELAY:-2}"
export ATIMA_MAX_CPUS=1
export MSYS_NO_PATHCONV=1

shared="docker compose -p atima-loadtest --env-file loadtest/loadtest.env -f deploy/compose.yaml -f loadtest/compose.mock.yaml -f loadtest/compose.loadtest.yaml"
local="docker compose -f loadtest/compose.local.yaml"

for workers in $workers_list; do
  export ATIMA_WORKERS="$workers"

  for users in $users_list; do
    echo "=== shared server, $workers workers, $users people ==="
    $shared up -d --wait atima caddy mock-issuer >/dev/null 2>&1 || { echo "the stack did not start"; exit 1; }
    $shared run --rm -T loadtest --users "$users" --minutes "$minutes" --think "$think" --flood 40 --signins 10 \
      --label "shared-w$workers-u$users-think$think" --note "$note; workers=$workers max_cpus=1 mock_delay=$MOCK_DELAY" 2>&1 | grep -v "Container"
    $shared logs atima 2>/dev/null | grep -c '"event":"job_timeout"' | sed 's/^/jobs stopped at the time limit: /'
    $shared down --volumes >/dev/null 2>&1
  done

  [ "${AGENTS:-1}" = "0" ] && continue

  echo "=== local server (AI apps), $workers workers ==="
  $local up -d --wait atima >/dev/null 2>&1 || { echo "the local server did not start"; exit 1; }
  $local run --rm -T loadtest --users 0 --minutes 0 --agents 2 --calls 6 --rounds 5 \
    --label "local-w$workers-agents" --note "$note; workers=$workers max_cpus=1" 2>&1 | grep -v "Container"
  $local down --volumes >/dev/null 2>&1
done
