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


## Results, November 2026

**Hardware and software.** One desktop computer: Intel Core i5-9600K
(6 cores at 3.7 GHz, no hyper-threading), 64 GB of memory, Windows 11.
Docker Desktop 29.9 on WSL2, given 6 CPUs and 31 GB. The atima image
(R 4.6.2, rbiom 4.0.0, mirai 2.7.4, httpuv 1.6.17), Caddy 2.11.9, the mock
provider and the load generator all ran on that machine, so the server
competed with the generator for the six cores. Each job was given one core
(`ATIMA_MAX_CPUS=1`); time limit 60 seconds; queue of ten jobs per worker;
at most 16 jobs per account. Every run started from a new, empty server
and lasted three minutes of browsing. 11,467 requests in all.

Regenerate the tables with `Rscript loadtest/summarise.R loadtest/results`.

### People browsing

Times in seconds. "Jobs" are the plots and table pages asked for; "busy"
are those answered 503 because the queue was full. "Response" is what the
person waits, "wait" the part of it spent waiting for a free worker.

| Workers | People | Seconds between actions | Jobs | Done | Busy (503) | Response: median | 95th pct. | Wait: median | 95th pct. | Page load: median | 95th pct. | Probe: 99th pct. |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 10 | 5  |  73 |  73 |   0 |  7.5 | 65.4 |  5.0 | 64.7 | 0.11 | 0.28 | 0.07 |
| 2 | 10 | 5  | 132 | 132 |   0 |  1.3 | 33.3 |  0.3 | 27.7 | 0.12 | 0.23 | 0.07 |
| 4 | 10 | 5  | 174 | 174 |   0 |  1.1 | 37.1 |  0.0 | 11.8 | 0.11 | 0.18 | 0.12 |
| 1 | 30 | 20 | 200 |  70 | 130 | 14.2 | 69.7 | 11.2 | 66.8 | 0.13 | 0.27 | 0.06 |
| 2 | 30 | 20 | 161 | 136 |  25 | 24.0 | 69.2 | 16.7 | 67.0 | 0.17 | 0.30 | 0.07 |
| 4 | 30 | 20 | 196 | 196 |   0 |  5.2 | 39.2 |  3.0 | 30.5 | 0.18 | 0.29 | 0.10 |
| 1 | 30 | 5  | 599 |  52 | 547 | 42.9 | 68.8 | 41.8 | 66.8 | 0.14 | 0.39 | 0.10 |
| 2 | 30 | 5  | 434 | 152 | 282 | 11.3 | 69.8 |  8.8 | 66.4 | 0.16 | 0.35 | 0.16 |
| 4 | 30 | 5  | 204 | 204 |   0 | 18.9 | 52.2 | 15.5 | 36.9 | 0.21 | 0.31 | 0.15 |

(A person who is answered 503 at once acts again sooner than one who
waits, which is why the overloaded runs count more jobs.)

How long each kind of job ran once it had a worker, over all runs:

| Job | Number | Median | 95th pct. | Longest |
|---|---|---|---|---|
| Table page (metadata, taxonomy) | 174 | 0.01 | 0.04 | 0.06 |
| `adiv_boxplot`  | 133 | 0.47 | 1.14 | 1.51 |
| `adiv_corrplot` |  53 | 0.38 | 1.60 | 2.44 |
| `taxa_forest`   |  49 | 0.69 | 1.65 | 2.00 |
| `taxa_stacked`  |  89 | 0.80 | 1.54 | 2.26 |
| `taxa_heatmap`  |  53 | 0.99 | 4.33 | 6.14 |
| `rare_corrplot` |  22 | 1.06 | 1.67 | 1.95 |
| `taxa_boxplot`  |  68 | 1.76 | 3.83 | 5.28 |
| `bdiv_boxplot`  |  49 | 0.83 | 39.7 | 41.1 |
| `bdiv_ord_plot` |  97 | 1.18 | 43.9 | 48.3 |

What the numbers say:

- **The main process stays responsive whatever the workers are doing.**
  In every run, including those where most jobs were turned away, a whole
  page load took 0.4 seconds or less at the 95th percentile, and the probe
  that needs no worker was answered within 0.3 seconds at worst. All 6,108
  requests for pages, static files, the schema and new sessions succeeded.
- **Capacity is the workers, and one kind of job sets it.** Almost every
  job takes one or two seconds. The exception is a permutation test on a
  large project: PERMANOVA with 999 permutations on the 1,006-sample
  example took 31 to 36 seconds (median; 48 at most) on one core, against
  under a second on the 50-sample example. In this test one action in
  ten was such a job, which is deliberately many. While one runs, its
  worker serves nobody else, so with one or two workers a few of them
  make everyone wait: hence waits of half a minute and more at the 95th
  percentile even where the median wait is under a second.
- **One worker is not enough for a shared server.** Ten people were
  served, but half of their requests waited five seconds or more.
- **Four workers** served 30 people acting every 20 seconds, and 30
  acting every 5 seconds, without turning anyone away; the median wait
  was 3 and 15 seconds. Two workers turned away 25 of 161 jobs in the
  first case.
- **No job reached the 60-second time limit**, but the large permutation
  tests come within 12 seconds of it on this hardware. A project a few
  times larger than 1,000 samples would pass it with the default
  settings.

### One account starting 40 jobs at once

The 40 exports arrived while the others browsed. With two workers and a
short queue ahead, 16 were accepted and 24 were answered 429, as the
per-account limit intends. In the other runs the outcome was decided
elsewhere: where the queue was already full of other people's jobs, most
of the 40 were answered 503 like everyone else's (39 or 40 with one
worker, 26 to 34 with two or four under 30 people); with four workers and 30 people acting every 20 seconds, 25 were
accepted and 15 answered 429; and with four workers and ten people the
exports, which take 0.03 seconds each, finished faster than they arrived,
so 38 were served and 2 refused. The limit is on jobs waiting or running
at one moment, not on how many an account may start in a minute.

### Signing in while the provider is slow

Ten people signed in at the same moment through a provider that took 2
seconds to answer each token request. In all nine runs every sign-in
succeeded; the callback took 2.3 seconds (median) and 4.3 at most, and the
probe was answered within 0.26 seconds throughout. Before this was
measured, atima asked the provider from its main process, which would
have stopped the whole server for those 2 seconds, ten times over; it now
asks in the background.

### AI apps

Two apps, each calling `make_plot` six times at once, five times over
(60 calls per run, against a server without accounts, where the
per-account limit does not apply). All 180 calls succeeded. Each answer
was 59 kB, the figure included.

| Workers | Response: median | 95th pct. |
|---|---|---|
| 1 | 8.8 | 12.3 |
| 2 | 4.2 |  7.5 |
| 4 | 2.2 |  5.6 |

### Stopping

`shutdown-stress.sh` (a busy worker pool, stopped in a new R process each
round): 300 rounds with R 4.6.2 and 300 with R 4.5.3. None hung or failed.

`stop-under-load.sh` (a whole server container, stopped while six
simulated people and two AI apps kept its one or two workers busy): in the
first 30 rounds, 29 stops were clean and one was not. That server went on
answering requests after the stop signal until Docker killed it 30
seconds later. The signal had arrived while R was running a request's
callback, where an interrupt ends the callback and nothing else. atima
now notes an interrupt that arrives there and stops when the callback
returns (`R/shutdown.R`). With that change, 60 rounds of 60 were clean,
in 1 to 6 seconds.

The browsing runs above were made before that change. One run was
repeated after it (`...-after-fix` in `results/`: two workers, ten people)
and gave the same page-load and probe times; its job times differ from
the first run's only as two runs of a random mix do.
