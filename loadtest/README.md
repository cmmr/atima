# Load and shutdown tests

Scripts for testing an atima server under load. They are kept in the
repository so that the tests can be run again, on other hardware and after
changes; they are not part of the R package. Use them on a test server
only: they make guests, sign made-up people in, and fill the queue on
purpose.

| File | What it is |
|---|---|
| `loadtest.R` | The load generator. One R process (packages curl and jsonlite) that plays many clients at once and times every request. |
| `run-series.sh` | Runs the load test against the container stack on this machine at several worker counts. |
| `mock-issuer.R`, `compose.mock.yaml` | A stand-in sign-in provider that signs anyone in under any name, and can be made slow. |
| `compose.loadtest.yaml`, `loadtest.env` | The load generator as a service of the test stack, and that stack's settings (plain HTTP, no rate limits). |
| `compose.local.yaml` | A server without accounts in a container, with the load generator beside it, for the AI-app part. |
| `shutdown-stress.sh`, `shutdown-once.R` | Stops a busy worker pool many times, looking for a stop that never returns. |
| `stop-under-load.sh` | Stops a whole busy server container many times. |
| `results/` | Results of the runs reported below. |


## What the load test does

**Browsing.** Each simulated person loads the page (the HTML page, the 26
static files it names, `POST /api/session/init` and `POST /api/schema`;
all but the first at once, as a browser does), then repeats: do one thing,
think for a while (exponentially distributed, 5 seconds on average). Half
the people work on the `hmp50` example (50 samples, 490 OTUs), half on
`gems` (1,006 samples, 767 OTUs). Four of five actions are a plot, the
rest a page of the metadata or taxonomy table. The plots:

| Plot | Share | Notes |
|---|---|---|
| `adiv_boxplot` | 22% | with statistics by group |
| `bdiv_ord_plot` | 18% | PERMANOVA with 999 permutations |
| `taxa_stacked` | 12% | |
| `taxa_heatmap`, `taxa_boxplot` | 10% each | |
| `adiv_corrplot`, `bdiv_boxplot` | 8% each | `bdiv_boxplot` with 999 permutations |
| `taxa_forest` | 7% | differential abundance |
| `rare_corrplot` | 5% | |

The two permutation tests get a new random seed every time, so they are
always computed. The other plots repeat with a few variations, as real
ones do, and rbiom's cache may answer them.

**A flood.** Half-way through, one more person starts 40 exports of a
distance matrix at once. Exports do not replace each other as a tab's
plots do, so this is what the per-account limit (16 by default) is for:
the first 16 are queued and the rest are answered 429.

**A probe.** Throughout, one client calls `POST /api/session/heartbeat`
twice a second. That request needs no worker; its response time shows
whether the main process keeps answering while the workers are busy.

**Signing in.** Afterwards ten people sign in at the same moment through
the mock provider, which waits 2 seconds before it answers the token
request, while the probe runs five times a second.

**AI apps** (a server without accounts, the only kind that offers `/mcp`).
Two apps each call the `make_plot` tool six times at once, wait for all
six answers, and repeat five times. Every answer carries the figure as a
PNG in base64.

For every request the generator records the time from sending to the last
byte of the answer and, for requests that used a worker, what the server
reports in its `Server-Timing` header: how long the job waited for a free
worker (`queue`) and how long it ran (`job`). The summary gives the
median, 90th, 95th and 99th percentile and the maximum of each, for
requests that succeeded; other answers are counted by status.


## Running it

Build the images once (`docker compose build` in `deploy/`), then from the
repository root:

```sh
sh loadtest/run-series.sh "1 2 4" "10 30"
```

This tries 1, 2 and 4 workers with 10 and with 30 people, three minutes
each, and takes about 40 minutes. Each run writes
`results/<time>-<label>.json` (the settings and the summary table) and
`results/<time>-<label>.requests.csv.gz` (one row per request).

To run one test by hand against the test stack:

```sh
cd deploy
stack="docker compose -p atima-loadtest --env-file ../loadtest/loadtest.env -f compose.yaml -f ../loadtest/compose.mock.yaml -f ../loadtest/compose.loadtest.yaml"
ATIMA_WORKERS=2 ATIMA_MAX_CPUS=1 MOCK_DELAY=2 $stack up -d
$stack run --rm loadtest --users 20 --minutes 3 --label my-test
$stack down --volumes
```

`loadtest.R` can also be pointed at any test server with `--base`; its
header lists the options. Against a server behind Caddy with the default
rate limits it will be turned away with status 429, because every
simulated person comes from one address: raise the `ATIMA_LIMIT_...`
settings for the test, as `loadtest.env` does.
